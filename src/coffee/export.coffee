_ = require 'underscore'
Csv = require 'csv'
archiver = require 'archiver'
path = require 'path'
tmp = require 'tmp'
Promise = require 'bluebird'
iconv = require 'iconv-lite'
fs = Promise.promisifyAll require('fs')
prompt = Promise.promisifyAll require('prompt')
{SphereClient} = require 'sphere-node-sdk'
Types = require './types'
Categories = require './categories'
Channels = require './channels'
CustomerGroups = require './customergroups'
Header = require './header'
Taxes = require './taxes'
ExportMapping = require './exportmapping'
Writer = require './io/writer'
queryStringParser = require 'querystring'
GLOBALS = require './globals'

# will clean temporary files even when an uncaught exception occurs
tmp.setGracefulCleanup()

# TODO:
# - JSDoc
class Export

  constructor: (@options = {}) ->
    @options.outputDelimiter = @options.outputDelimiter || ","
    @options.templateDelimiter = @options.templateDelimiter || ","
    @options.encoding = @options.encoding || "utf8"

    @queryOptions =
      queryString: @options.export?.queryString?.trim()
      isQueryEncoded: @options.export?.isQueryEncoded
      filterVariantsByAttributes: @_parseQuery(
        @options.export?.filterVariantsByAttributes
      )
      filterPrices: @_parseQuery(@options.export?.filterPrices)

    @client = new SphereClient @options.client

    # TODO: using single mapping util instead of services
    @typesService = new Types()
    @categoryService = new Categories()
    @channelService = new Channels()
    @customerGroupService = new CustomerGroups()
    @taxService = new Taxes()

    @createdFiles = {}

  _parseQuery: (queryStr) ->
    if !queryStr then return null
    return _.map(
      queryStr.split('&'),
      (filter) ->
        filter = filter.split('=')
        if filter[1] == 'true' || filter[1] == 'false'
          filter[1] = filter[1] == 'true'
        return {
          name: filter[0]
          value: filter[1]
        }
    )

  _filterPrices: (prices, filters) ->
    _.filter(prices, (price) ->
      return _.reduce(
        filters,
        (filterOutPrice, filter) ->
          return filterOutPrice && price[filter.name] == filter.value
      , true)
    )

  _filterVariantsByAttributes: (variants, filter) ->
    filteredVariants = _.filter(variants, (variant) ->
      return if filter?.length > 0
        _.reduce(
          filter,
          (filterOutVariant, filter) ->
            # filter attributes
            attribute = _.findWhere(variant.attributes, {
              name: filter.name
            })
            return filterOutVariant && !!attribute &&
              (attribute.value == filter.value)
        , true)
      else
        true
    )

    # filter prices of filtered variants
    return _.map(filteredVariants, (variant) =>
      if @queryOptions.filterPrices?.length > 0
        variant.prices = @_filterPrices(
          variant.prices,
          @queryOptions.filterPrices
        )
        if variant.prices.length == 0 then return null
      return variant
    )

  _initMapping: (header) ->
    _.extend @options,
      channelService: @channelService
      categoryService: @categoryService
      typesService: @typesService
      customerGroupService: @customerGroupService
      taxService: @taxService
      header: header
    new ExportMapping(@options)

  # return the correct product service in case query string is used or not
  _getProductService: (staged = true, customWherePredicate = false) ->
    productsService = @client.productProjections
    perPage = 100

    if @queryOptions.queryString
      query = @queryOptions.queryString
      if @queryOptions.isQueryEncoded
        query = decodeURIComponent(query)

      if customWherePredicate
        query = @_appendPredicateToQueryString(query, customWherePredicate)

      productsService.byQueryString(query, false)
      productsService
    else
      productsService.where(customWherePredicate || '')
      productsService.all().perPage(perPage).staged(staged)

  _fetchResources: =>
    data = [
      @typesService.getAll @client
      @categoryService.getAll @client
      @channelService.getAll @client
      @customerGroupService.getAll @client
      @taxService.getAll @client
    ]
    Promise.all(data)
    .then ([productTypes, categories, channels, customerGroups, taxes]) =>
      @typesService.buildMaps productTypes.body.results
      @categoryService.buildMaps categories.body.results
      @channelService.buildMaps channels.body.results
      @customerGroupService.buildMaps customerGroups.body.results
      @taxService.buildMaps taxes.body.results

      console.warn "Fetched #{productTypes.body.total} product type(s)."
      Promise.resolve({productTypes, categories, channels, customerGroups, taxes})

  exportDefault: (templateContent, outputFile, staged = true) =>
    @_fetchResources()
    .then ({productTypes}) =>
      @export templateContent, outputFile, productTypes, staged, false, true

  _archiveFolder: (inputFolder, outputFile) ->
    output = fs.createWriteStream(outputFile)
    archive = archiver 'zip'

    new Promise (resolve, reject) ->
      output.on 'close', () -> resolve()
      archive.on 'error', (err) -> reject(err)
      archive.pipe output

      archive.bulk([
        { expand: true, cwd: inputFolder, src: ['**'], dest: 'products'}
      ])
      archive.finalize()

  exportFull: (output, staged = true) =>
    lang = GLOBALS.DEFAULT_LANGUAGE
    console.log 'Creating full export for "%s" language', lang

    @_fetchResources()
    .then ({productTypes}) =>
      if not productTypes.body.results.length
        return Promise.reject("Project does not have any productTypes.")

      tempDir = tmp.dirSync({ unsafeCleanup: true })
      console.log "Creating temp directory in %s", tempDir.name

      Promise.map productTypes.body.results, (type) =>
        console.log 'Processing products with productType "%s"', type.name
        csv = new ExportMapping().createTemplate(type, [lang])
        fileName = _.slugify(type.name)+"_"+type.id+"."+@options.exportFormat
        filePath = path.join(tempDir.name, fileName)
        condition = 'productType(id="'+type.id+'")'

        @export csv.join(@options.templateDelimiter), filePath, productTypes, staged, condition, false
      , { concurrency: 1}
      .then =>
        console.log "All productTypes were processed - archiving output folder"
        @_archiveFolder tempDir.name, output
      .then ->
        console.log "Folder was archived and saved to %s", output
        tempDir.removeCallback()
        Promise.resolve "Export done."

  _appendPredicateToQueryString: (queryString, predicate) =>
    query = queryStringParser.parse(queryString)
    query.where =
      (if query.where then query.where + " AND #{predicate}" else predicate)
    decodeURIComponent(queryStringParser.stringify(query))

  _processChunk: (writer, products, productTypes, createFileWhenEmpty, header, exportMapper, outputFile) =>
    console.warn "Fetched #{products.body.count} product(s)."
    data = []
    # if there are no products to export
    if not products.body.count && not createFileWhenEmpty
      return Promise.resolve()

    (if @createdFiles[outputFile]
      Promise.resolve()
    else
      @createdFiles[outputFile] = 1
      writer.setHeader header.rawHeader
    )
    .then =>
      _.each products.body.results, (product) =>
        # filter variants
        product.variants = @_filterVariantsByAttributes(
          product.variants,
          @queryOptions.filterVariantsByAttributes
        )
        # filter masterVariant
        [ product.masterVariant ] = @_filterVariantsByAttributes(
          [ product.masterVariant ],
          @queryOptions.filterVariantsByAttributes
        )
        # remove all the variants that don't meet the price condition
        product.variants = _.compact(product.variants)
        data = data.concat exportMapper.mapProduct(
          product,
          productTypes.body.results
        )
      writer.write data
      .catch (err) ->
        console.dir(err)

  export: (templateContent, outputFile, productTypes, staged = true, customWherePredicate = false, createFileWhenEmpty = false) ->
    @_parse(templateContent)
    .then (header) =>
      writer = new Writer
        csvDelimiter: @options.outputDelimiter,
        encoding: @options.encoding,
        format: @options.exportFormat,
        outputFile: outputFile
      errors = header.validate()
      rowsReaded = 0

      unless _.size(errors) is 0
        Promise.reject errors
      else
        header.toIndex()
        header.toLanguageIndex()
        exportMapper = @_initMapping(header)

        _.each productTypes.body.results, (productType) ->
          header._productTypeLanguageIndexes(productType)

        @_getProductService(staged, customWherePredicate)
        .process( (products) =>
          rowsReaded += products.body.results.length
          @_processChunk writer, products, productTypes, createFileWhenEmpty, header, exportMapper, outputFile
        , {accumulate: false})
        .then ->
          if createFileWhenEmpty || rowsReaded
            writer.flush()
          else
            Promise.resolve()
        .then ->
          Promise.resolve "Export done."
        .catch (err) ->
          console.dir(err, {depth: 10})

  exportAsJson: (outputFile) ->
    # TODO:
    # - use process to export products in batches
    # - use streams to write data chunks
    @_getProductService()
    .then (result) =>
      products = result.body.results
      if _.size(products) is 0
        Promise.resolve 'No products found.'
      else
        console.warn "Number of fetched products: #{result.body.count}/#{result.body.total}."
        @_saveJSON(outputFile, products)
        .then -> Promise.resolve 'Export done.'

  createTemplate: (languages, outputFile, allProductTypes = false) ->
    @typesService.getAll(@client)
    .then (result) =>
      productTypes = result.body.results
      if _.size(productTypes) is 0
        Promise.reject 'Can not find any product type.'
      else
        idsAndNames = _.map productTypes, (productType) ->
          productType.name

        if allProductTypes
          allHeaders = []
          exportMapping = new ExportMapping()
          _.each productTypes, (productType) ->
            allHeaders = allHeaders.concat exportMapping.createTemplate(productType, languages)
          csv = _.uniq allHeaders
          @_saveCSV(outputFile, [csv])
          .then -> Promise.resolve 'Template for all product types generated.'
        else
          _.each idsAndNames, (entry, index) ->
            console.warn '  %d) %s', index, entry
          prompt.start()
          property =
            name: 'number'
            message: 'Enter the number of the producttype.'
            validator: /\d+/
            warning: 'Please enter a valid number'
          prompt.getAsync property
          .then (result) =>
            productType = productTypes[parseInt(result.number)]
            if productType
              console.warn "Generating template for product type '#{productType.name}' (id: #{productType.id})."
              process.stdin.destroy()
              csv = new ExportMapping().createTemplate(productType, languages)
              @_saveCSV(outputFile, [csv])
              .then -> Promise.resolve 'Template generated.'
            else
              Promise.reject 'Please re-run and select a valid number.'

  _saveCSV: (file, content, append) =>
    flag = if append then 'a' else 'w'
    new Promise (resolve, reject) =>
      parsedCsv = Csv().from(content, {delimiter: @options.outputDelimiter})
      opts =
        flag: flag

      if file
        parsedCsv.to.string (res) =>
          converted = iconv.encode(res+'\n', @options.encoding)
          fs.writeFileAsync file, converted, opts
          .then -> resolve()
          .catch (err) -> reject err
      else
        parsedCsv.to.stream process.stdout, opts

      parsedCsv
      .on 'error', (err) -> reject err
      .on 'close', (count) -> resolve count

  _saveJSON: (file, content) ->
    content = JSON.stringify content, null, 2
    opts =
      encoding: 'utf8'

    if file then fs.writeFileAsync file, content, opts
    else process.stdout.write content

  _parse: (csvString) =>
    new Promise (resolve, reject) =>
      csvString = _.trim(csvString, @options.templateDelimiter)
      Csv().from.string(csvString, {delimiter: @options.templateDelimiter})
      .to.array (data, count) ->
        header = new Header(data[0])
        resolve header
      .on 'error', (err) -> reject err

module.exports = Export