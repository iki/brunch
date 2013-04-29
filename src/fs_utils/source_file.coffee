'use strict'

async = require 'async'
debug = require('debug')('brunch:source-file')
fs = require 'fs'
sysPath = require 'path'
logger = require 'loggy'

# Run all linters.
lint = (data, path, linters, callback) ->
  if linters.length is 0
    callback null
  else
    async.forEach linters, (linter, callback) ->
      linter.lint data, path, callback
    , callback

# Extract files that depend on current file.
getDependencies = (data, path, compiler, callback) ->
  if compiler.getDependencies
    compiler.getDependencies data, path, callback
  else
    callback null, []

pipeline = (realPath, path, linters, compiler, callback) ->
  callbackError = (type, stringOrError) =>
    error = if stringOrError instanceof Error
      stringOrError
    else
      new Error stringOrError
    error.brunchType = type
    callback error

  fs.readFile realPath, 'utf-8', (error, data) =>
    return callbackError 'Reading', error if error?
    try
      debug "Loaded file '%s'%s [%s]", path,
        if realPath isnt path then " -> '" + realPath + "'" else ''
        data.length
      lint data, path, linters, (error) =>
        try
          if error?.match /^warn\:\s/i
            logger.warn "Linting of #{path}: #{error}"
          else
            return callbackError 'Linting', error if error?
          compiler.compile data, path, (error, compiled) =>
            try
              return callbackError 'Compiling', error if error?
              getDependencies data, path, compiler, (error, dependencies) =>
                try
                  return callbackError 'Dependency parsing', error if error?
                  callback null, {dependencies, compiled}
                catch error
                  callback error
            catch error
              callback error
        catch error
          callback error
    catch error
      callback error

updateCache = (cache, realPath, path, error, result, wrap) ->
  if error?
    cache.error = error
  else
    {dependencies, compiled} = result
    cache.error = null
    cache.dependencies = dependencies
    cache.compilationTime = Date.now()
    cache.data = wrap compiled if compiled?
    debug "Cached file '%s'%s [%s:%s]", path,
      if realPath isnt path then " -> '" + realPath + "'" else ''
      if compiled? then compiled.length else '-'
      if cache.data? then cache.data.length else '-'
  cache

makeWrapper = (wrapper, path, isWrapped, isntModule) ->
  (data) ->
    if isWrapped then wrapper path, data, isntModule else data

makeCompiler = (realPath, path, cache, linters, compiler, wrap) ->
  (callback) ->
      pipeline realPath, path, linters, compiler, (error, data) =>
        try
          updateCache cache, realPath, path, error, data, wrap
          throw error if error?
          callback null, cache.data
        catch error
          logger.error error.toString()
          callback error

# A file that will be compiled by brunch.
module.exports = class SourceFile
  constructor: (path, compiler, linters, wrapper, isHelper, isVendor) ->
    isntModule = isHelper or isVendor
    isWrapped = compiler.type in ['javascript', 'template']

    # If current file is provided by brunch plugin, use fake path.
    realPath = path
    @path = if isHelper
      compilerName = compiler.constructor.name
      fileName = "brunch-#{compilerName}-#{sysPath.basename realPath}"
      sysPath.join 'vendor', 'scripts', fileName
    else
      path
    @type = compiler.type
    wrap = makeWrapper wrapper, @path, isWrapped, isntModule
    @data = ''
    @dependencies = []
    @compilationTime = null
    @error = null
    @compile = makeCompiler realPath, @path, this, linters, compiler, wrap
    debug '%s%s (%s%s)', @path,
      if isHelper then ' -> ' + realPath else ''
      @type
      if @isVendor then '|vendor' else ''
    Object.seal this
