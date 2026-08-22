#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/carnet_builder"
require_relative "lib/help"

argv = ARGV.dup
carnet_arg = nil
if (i = argv.index("-c"))
  carnet_arg = argv[i + 1]
  argv.slice!(i, 2)
end

command, arg1 = argv

case command
when "-h", "--help"
  puts USAGE
when nil, ".", "build"
  path = command == "build" ? (arg1 || ".") : "."
  dir = File.expand_path(path)
  abort "dossier introuvable : #{dir}" unless Dir.exist?(dir)

  begin
    if carnet_arg
      abort "aucune chanson (.lyr/.lyrics) trouvée dans #{dir}" unless CarnetBuilder.song_folder?(dir)

      out_path = CarnetBuilder.build(File.expand_path(carnet_arg), only_song: File.basename(dir))
    elsif CarnetBuilder.carnet_folder?(dir)
      out_path = CarnetBuilder.build(dir)
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
  abort USAGE
end
