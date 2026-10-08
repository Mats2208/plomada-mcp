# frozen_string_literal: true

# Plomada: a Model Context Protocol bridge for SketchUp that models
# architecture from AutoCAD MCP Pro plans. This loader only registers the
# extension; everything else lives in the plomada/ folder.
require 'sketchup.rb'
require 'extensions.rb'
require_relative 'plomada/version'

module Plomada
  PLUGIN_DIR = File.join(__dir__, 'plomada').tr('\\', '/')

  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new(EXTENSION_NAME, File.join(PLUGIN_DIR, 'main'))
    extension.description = 'Local MCP server for Claude: builds an exact 3D house from an AutoCAD MCP Pro plan. ' \
                            'Loopback only, token authenticated.'
    extension.version = VERSION
    extension.creator = 'Mats2208'
    extension.copyright = '2026 Mats2208, MIT License'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
