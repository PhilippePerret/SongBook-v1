#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/carnet_builder"
require_relative "lib/help"

argv = ARGV.dup
cover = false
%w[-c --cover].each do |flag|
  if (i = argv.index(flag))
    cover = true
    argv.delete_at(i)
  end
end
debug_marks = !!argv.delete("-x")

command, arg1 = argv

case command
when "-h", "--help"
  system("clear")
  system("clear")
  puts colorize_help(USAGE)
when nil, ".", "build"
  if command == "build" && arg1 == "cover"
    cover = true
    arg1 = nil
  end
  path = command == "build" ? (arg1 || ".") : "."
  dir = File.expand_path(path)
  abort "dossier introuvable : #{dir}" unless Dir.exist?(dir)

  begin
    if CarnetBuilder.carnet_folder?(dir)
      out_path = CarnetBuilder.build(dir, cover: cover, debug_marks: debug_marks)
    elsif CarnetBuilder.song_folder?(dir)
      out_path = CarnetBuilder.build_song(dir)
    else
      abort "ni carnet (.tdm/.toc) ni chanson (.lyr/.lyrics) reconnu dans #{dir}"
    end
    puts out_path
  rescue RuntimeError => e
    abort "Erreur : #{e.message}"
  end
else
  abort colorize_help(USAGE)
end
