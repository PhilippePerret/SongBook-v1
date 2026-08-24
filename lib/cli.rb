# frozen_string_literal: true

require "tty-prompt"
require_relative "carnet_builder"
require_relative "help"
require_relative "diags_page"
require_relative "app_config"
require_relative "song_creator"
require_relative "chord_placer"
require_relative "file_finder"
require_relative "locale"

# Dispatch de la ligne de commande `songbook` — parsing ARGV + routage vers la
# logique métier (CarnetBuilder, DiagsPage, ...). `songbook.rb` reste un simple
# point d'entrée qui appelle `CLI.run(ARGV)`.
module CLI
  def self.run(argv)
    system("clear")
    system("clear")

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
      puts colorize_help(USAGE)
    when "diags"
      puts DiagsPage.build_and_open!
    when "create"
      case arg1
      when "song"
        begin
          SongCreator.run(arg2, arg3)
        rescue Interrupt
          puts
          puts Loc.get("song_creation_cancelled")
        end
      else
        abort colorize_help(USAGE)
      end
    when "add"
      case arg1
      when "chords"
        begin
          song_folder = resolve_song_folder(arg2)
          lyr_path = FileFinder.find(song_folder, :lyr)
          abort "aucun .lyr/.lyrics trouvé dans #{song_folder}" unless lyr_path

          ChordPlacer.run(lyr_path)
        rescue Interrupt
          puts
        end
        puts Loc.get("edition_cancelled")
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

  # Titre TAPÉ PAR L'USER (ex. `songbook add chords "titre"`) : chemin direct accepté tel
  # quel, sinon correspondance EXACTE (`find_song_by_title`, sur le nom de dossier ou le
  # `title` de la fiche). Rien d'exact -> Levenshtein (`fuzzy_find_songs`), proposé à
  # l'user pour choix — MÊME 1 SEUL résultat, jamais retenu tel quel sans confirmation.
  def self.resolve_song_folder(name)
    return File.expand_path(name) if name && Dir.exist?(File.expand_path(name))

    songs_dir = AppConfig.songs_dir
    matches = CarnetBuilder.find_song_by_title(songs_dir, name.to_s)
    return matches.first[:folder] if matches.size == 1
    return select_song(Loc.get("song_multiple_matches"), matches) if matches.size > 1

    candidates = CarnetBuilder.fuzzy_find_songs(songs_dir, name.to_s)
    abort "chanson introuvable : #{name}" if candidates.empty?

    select_song(Loc.get("song_not_found_did_you_mean"), candidates)
  end

  def self.select_song(message, songs)
    choices = songs.map { |s| { name: s[:title] ? "#{s[:name]} (#{s[:title]})" : s[:name], value: s[:folder] } }
    choices << { name: Loc.get("none_of_these"), value: nil }
    folder = TTY::Prompt.new.select(message, choices)
    abort "chanson introuvable" unless folder

    folder
  end
end
