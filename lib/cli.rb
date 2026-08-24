# frozen_string_literal: true

require_relative "carnet_builder"
require_relative "help"
require_relative "diags_page"
require_relative "app_config"
require_relative "song_creator"

# Dispatch de la ligne de commande `songbook` — parsing ARGV + routage vers la
# logique métier (CarnetBuilder, DiagsPage, ...). `songbook.rb` reste un simple
# point d'entrée qui appelle `CLI.run(ARGV)`.
module CLI
  def self.run(argv)
    argv = argv.dup
    cover = false
    %w[-c --cover].each do |flag|
      if (i = argv.index(flag))
        cover = true
        argv.delete_at(i)
      end
    end
    debug_marks = !!argv.delete("-x")

    # `-b/--book PATH` : sortir UNE chanson (arg1) EXACTEMENT comme elle sortirait dans CE
    # carnet-là (layout/page_count/marges résolus du carnet, voir `CarnetBuilder.build`,
    # `only_song:`) — sans reconstruire tout le carnet.
    book_path = nil
    %w[-b --book].each do |flag|
      if (i = argv.index(flag))
        book_path = argv[i + 1]
        argv.delete_at(i + 1)
        argv.delete_at(i)
      end
    end

    command, arg1, arg2, arg3 = argv

    case command
    when "-h", "--help"
      system("clear")
      system("clear")
      puts colorize_help(USAGE)
    when "diags"
      puts DiagsPage.build_and_open!
    when "create"
      case arg1
      when "song"
        puts SongCreator.run(arg2, arg3)
      else
        abort colorize_help(USAGE)
      end
    when nil, ".", "build"
      if command == "build" && arg1 == "cover"
        cover = true
        arg1 = nil
      end
      path = command == "build" ? (arg1 || ".") : "."
      dir = File.expand_path(path)
      abort "dossier introuvable : #{dir}" unless Dir.exist?(dir)

      begin
        if book_path
          book_dir = File.expand_path(book_path)
          abort "dossier de carnet introuvable : #{book_dir}" unless Dir.exist?(book_dir)
          abort "pas un carnet (.tdm/.toc introuvable) : #{book_dir}" unless CarnetBuilder.carnet_folder?(book_dir)
          out_path = CarnetBuilder.build(book_dir, only_song: File.basename(dir), debug_marks: debug_marks)
        elsif CarnetBuilder.carnet_folder?(dir)
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
  end
end
