#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/carnet_builder"

USAGE = "Usage : songbook build <dossier-carnet>"

command, arg = ARGV

case command
when "build"
  abort USAGE unless arg

  out_path = CarnetBuilder.build(File.expand_path(arg))
  puts out_path
else
  abort USAGE
end
