# frozen_string_literal: true

require "readline"
require "shellwords"
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
  # `songbook song open` : ordre d'affichage + libellés clairs — TOUS les types connus
  # (`FileFinder::EXTENSIONS`), pas seulement `.lyr`/`.infos`. `.lyr`/`.gab` présélectionnés
  # par défaut (Phil).
  SONG_FILE_KINDS = {
    lyr: "Paroles (.lyr)",
    gab: "Gabarit (.gab)",
    inf: "Informations (.inf)",
    lay: "Mise en page (.lay)",
    sch: "Schéma (.sch)",
    tdm: "Table des matières (.tdm)",
  }.freeze

  HISTORY_FILE = File.expand_path("~/.songbook_history")
  PROMPT_STATE_FILE = File.expand_path("~/.songbook_prompt_icon")
  PROMPT_ICONS = ["🎤", "🎸"].freeze

  # Mode REPL (`songbook -i`) : une invite qui redonne la main après chaque commande
  # au lieu de quitter — Readline pour l'historique/édition de ligne (même lib que
  # celle utilisée par `mysql`/`irb`). `abort` (SystemExit) et Ctrl+C (Interrupt)
  # sont rattrapés ici pour ne pas tuer la boucle. Icône alternée à chaque lancement
  # (état persisté dans un petit fichier) (Phil).
  def self.run_interactive
    system("clear")
    load_history
    prompt = "#{next_prompt_icon}> "
    loop do
      line = begin
        Readline.readline(prompt, true)
      rescue Interrupt # Ctrl+C sur l'invite (rien à annuler) -> sortie silencieuse
        break
      end
      break if line.nil? # Ctrl+D

      line = line.strip
      next if line.empty?
      break if %w[exit quit].include?(line)

      begin
        run(Shellwords.split(line), interactive: true)
      rescue Interrupt # Ctrl+C pendant une commande -> annule la commande, pas la boucle
        puts
      rescue SystemExit
        nil
      end
    end
  ensure
    save_history
  end

  def self.next_prompt_icon
    last = File.exist?(PROMPT_STATE_FILE) ? File.read(PROMPT_STATE_FILE).strip : nil
    icon = PROMPT_ICONS[((PROMPT_ICONS.index(last) || -1) + 1) % PROMPT_ICONS.size]
    File.write(PROMPT_STATE_FILE, icon)
    icon
  rescue StandardError
    PROMPT_ICONS.first
  end

  def self.load_history
    return unless File.exist?(HISTORY_FILE)

    File.readlines(HISTORY_FILE, chomp: true).each { |line| Readline::HISTORY.push(line) }
  end

  def self.save_history
    File.write(HISTORY_FILE, Readline::HISTORY.to_a.last(500).join("\n") << "\n")
  rescue StandardError
    nil
  end

  def self.run(argv, interactive: false)
    unless interactive
      system("clear")
      system("clear")
    end

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
        abort unknown_command_message("create #{arg1}")
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
        abort unknown_command_message("add #{arg1}")
      end
    when "song"
      case arg1
      when "id"
        begin
          song_folder = resolve_song_folder(arg2)
          infos_path = FileFinder.find(song_folder, :inf)
          infos = infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : {}
          value = infos["id"].to_s.strip.empty? ? (infos["title"] || File.basename(song_folder)) : infos["id"]
          line = "- #{value}"
          IO.popen("pbcopy", "w") { |f| f.write(line) }
          puts line
        rescue Interrupt
          puts
          puts Loc.get("edition_cancelled")
        end
      else
        abort unknown_command_message("song #{arg1}")
      end
    when "open"
      case arg1
      when "song"
        begin
          song_folder = resolve_song_folder(arg2)
          infos_path = FileFinder.find(song_folder, :inf)
          infos = infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : {}
          title = infos["title"] || File.basename(song_folder)

          # `.gab` TOUJOURS proposé, créé (vide) s'il n'existe pas encore (Phil) — même
          # root-name que les autres fichiers de la chanson (`.lyr`/`.infos`), convention
          # déjà en usage (ex. "w.gab"/"w.lyr"/"w.infos").
          gab_path = FileFinder.find(song_folder, :gab)
          unless gab_path
            root = File.basename(FileFinder.find(song_folder, :lyr) || infos_path || "c.x", ".*")
            gab_path = File.join(song_folder, "#{root}.gab")
            File.write(gab_path, "")
          end

          choices = []
          defaults = []
          SONG_FILE_KINDS.each do |kind, label|
            path = kind == :gab ? gab_path : FileFinder.find(song_folder, kind)
            next unless path

            choices << { name: label, value: path }
            defaults << choices.length if %i[lyr gab].include?(kind)
          end
          choices << { name: Loc.get("open_folder_label"), value: :folder }
          abort "aucun fichier connu trouvé dans #{song_folder}" if choices.empty?

          puts "Ouverture de « #{title} »"
          selected = TTY::Prompt.new.multi_select(Loc.get("open_which_files"), choices, default: defaults, echo: false, show_help: false)
          files = selected - [:folder]
          system("open", "-a", AppConfig.user_song_editor, *files) unless files.empty?
          SongCreator.open_in_file_manager(song_folder) if selected.include?(:folder)
        rescue Interrupt
          puts
          puts Loc.get("edition_cancelled")
        end
      else
        abort unknown_command_message("open #{arg1}")
      end
    when nil, ".", "build"
      if command == "build" && arg1 == "cover"
        cover = true
        arg1 = nil
      end
      begin
        if command == "build" && arg1 == "song" && arg2
          target = resolve_song_target(arg2)
        elsif command == "build" && %w[songbook sb].include?(arg1) && arg2
          target = resolve_carnet_target(arg2)
        elsif command == "build" && arg1 && arg1 != "." && !Dir.exist?(File.expand_path(arg1))
          target = resolve_build_target(arg1)
        else
          path = command == "build" ? (arg1 || ".") : "."
          dir = File.expand_path(path)
          abort "dossier introuvable : #{dir}" unless Dir.exist?(dir)
          kind = CarnetBuilder.carnet_folder?(dir) ? :carnet : (CarnetBuilder.song_folder?(dir) ? :song : nil)
          abort "ni carnet (.tdm/.toc) ni chanson (.lyr/.lyrics) reconnu dans #{dir}" unless kind
          target = { kind: kind, folder: dir }
        end

        if book_path
          book_dir = File.expand_path(book_path)
          abort "dossier de carnet introuvable : #{book_dir}" unless Dir.exist?(book_dir)
          abort "pas un carnet (.tdm/.toc introuvable) : #{book_dir}" unless CarnetBuilder.carnet_folder?(book_dir)
          out_path = CarnetBuilder.build(book_dir, only_song: File.basename(target[:folder]), debug_marks: debug_marks)
        elsif target[:kind] == :carnet
          out_path = CarnetBuilder.build(target[:folder], cover: cover, debug_marks: debug_marks)
        else
          out_path = CarnetBuilder.build_song(target[:folder])
        end
        puts out_path
      rescue Interrupt
        puts
      rescue RuntimeError => e
        abort "Erreur : #{e.message}"
      end
    else
      abort unknown_command_message(command)
    end
  end

  def self.unknown_command_message(command)
    "commande inconnue : #{command} (aide : songbook -h)"
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
    return select_song(nil, matches) if matches.size > 1

    candidates = CarnetBuilder.fuzzy_find_songs(songs_dir, name.to_s)
    abort "chanson introuvable : #{name}" if candidates.empty?

    select_song(Loc.get("song_not_found_did_you_mean"), candidates)
  end

  def self.select_song(message, songs)
    choices = songs.map { |s| { name: s[:title] ? "#{s[:name]} (#{s[:title]})" : s[:name], value: s[:folder] } }
    choices << { name: Loc.get("none_of_these"), value: nil }
    folder = TTY::Prompt.new.select(message.to_s, choices, show_help: false, filter: true)
    abort "aucune correspondance retenue" unless folder

    folder
  end

  # Chanson : correspondance exacte/préfixe/mots, sinon Levenshtein extrêmement proche
  # (distance <= 1, `CarnetBuilder.very_close_match`) — toujours confirmée, jamais
  # retenue telle quelle. `nil` si rien de tout ça (laisse l'appelant décider de la suite).
  def self.matched_song(songs_dir, name)
    matches = CarnetBuilder.find_song_by_title(songs_dir, name)
    return { kind: :song, folder: matches.first[:folder] } if matches.size == 1
    return { kind: :song, folder: select_song(nil, matches) } if matches.size > 1

    close = CarnetBuilder.very_close_match(CarnetBuilder.all_songs(songs_dir), name)
    close ? { kind: :song, folder: select_song(nil, [close]) } : nil
  end

  # Pendant carnet de `matched_song`.
  def self.matched_carnet(songbooks_dir, name)
    matches = CarnetBuilder.find_carnet_by_title(songbooks_dir, name)
    return { kind: :carnet, folder: matches.first[:folder] } if matches.size == 1
    return { kind: :carnet, folder: select_song(nil, matches) } if matches.size > 1

    close = CarnetBuilder.very_close_match(CarnetBuilder.all_carnets(songbooks_dir), name)
    close ? { kind: :carnet, folder: select_song(nil, [close]) } : nil
  end

  # `songbook build song "titre"` : recherche restreinte aux chansons — rien trouvé ->
  # liste complète des chansons (filtrable, "Aucune de celles-ci" pour renoncer).
  def self.resolve_song_target(name)
    songs_dir = AppConfig.songs_dir
    matched_song(songs_dir, name) || begin
      puts Loc.get("build_nothing_found")
      { kind: :song, folder: select_song(nil, CarnetBuilder.all_songs(songs_dir)) }
    end
  end

  # `songbook build songbook|sb "titre"` : pendant carnet de `resolve_song_target`.
  def self.resolve_carnet_target(name)
    songbooks_dir = AppConfig.songbooks_dir
    matched_carnet(songbooks_dir, name) || begin
      puts Loc.get("build_nothing_found")
      { kind: :carnet, folder: select_song(nil, CarnetBuilder.all_carnets(songbooks_dir)) }
    end
  end

  # `songbook build "titre"` quand l'argument n'est pas un dossier existant, ET SANS type
  # précisé (ni `song` ni `songbook`/`sb`) : recherche exacte/préfixe/mots CHANSONS
  # D'ABORD, PUIS CARNETS (Phil), avec la même règle "extrêmement proche" que ci-dessus.
  # Sinon : rien trouvé, menu "Construire : un carnet / une chanson / renoncer" (Phil —
  # pas de suggestions floues hasardeuses ici, contrairement à `resolve_song_folder`).
  def self.resolve_build_target(name)
    songs_dir = AppConfig.songs_dir
    match = matched_song(songs_dir, name)
    return match if match

    songbooks_dir = AppConfig.songbooks_dir
    match = matched_carnet(songbooks_dir, name)
    return match if match

    build_not_found_menu(songs_dir, songbooks_dir)
  end

  def self.build_not_found_menu(songs_dir, songbooks_dir)
    puts Loc.get("build_nothing_found")
    choice = TTY::Prompt.new.select(Loc.get("build_what_to_build"), [
      { name: Loc.get("build_choice_carnet"), value: :carnet },
      { name: Loc.get("build_choice_song"), value: :song },
      { name: Loc.get("build_choice_cancel"), value: nil },
    ], show_help: false)

    case choice
    when :carnet
      { kind: :carnet, folder: select_song(nil, CarnetBuilder.all_carnets(songbooks_dir)) }
    when :song
      { kind: :song, folder: select_song(nil, CarnetBuilder.all_songs(songs_dir)) }
    else
      abort Loc.get("build_cancelled")
    end
  end
end
