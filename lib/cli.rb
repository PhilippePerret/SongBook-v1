# frozen_string_literal: true

require "readline"
require "shellwords"
require "tty-prompt"
require_relative "carnet_builder"
require_relative "layout"
require_relative "help"
require_relative "diags_page"
require_relative "app_config"
require_relative "song_creator"
require_relative "songbook_creator"
require_relative "chord_placer"
require_relative "file_finder"
require_relative "locale"
require_relative "session"
require_relative "song_resolver"
require_relative "tablator_assistant"
require_relative "ansi_colors"
require_relative "idml_cover_builder"
require_relative "kdp"
require_relative "../tools/DiagSchem/diagschem"
require_relative "../tools/ChordDiagram/generate_chord_diagrams"

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
  PROMPT_ICON = "🎸"

  # Mode REPL (`songbook -i`) : une invite qui redonne la main après chaque commande
  # au lieu de quitter — Readline pour l'historique/édition de ligne (même lib que
  # celle utilisée par `mysql`/`irb`). `abort` (SystemExit) et Ctrl+C (Interrupt)
  # sont rattrapés ici pour ne pas tuer la boucle.
  def self.run_interactive
    system("clear")
    load_history
    prompt = "#{PROMPT_ICON}> "
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
        # `Shellwords.split` renvoie des tokens taggés ASCII-8BIT quel que soit
        # l'encoding de la ligne source — `unicode_normalize` (via `CarnetBuilder.
        # slugify`) plante dessus (Encoding::CompatibilityError), même sur du texte
        # pur ASCII (Phil, bug constaté 2026-08-25).
        args = Shellwords.split(line).map { |t| t.force_encoding(Encoding::UTF_8) }
        run(args, interactive: true)
      rescue Interrupt # Ctrl+C pendant une commande -> annule la commande, pas la boucle
        puts
      rescue SystemExit
        nil
      rescue ArgumentError => e # ex. guillemet non fermé (`Shellwords.split`) -> pas de crash du REPL
        puts "commande illisible : #{e.message}"
      end
    end
  ensure
    save_history
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

    # `--create`/`--build` : zappent le 1er choix de `tablator assistant` (voir
    # `TablatorAssistant.run`).
    tab_create = !!argv.delete("--create")
    tab_build = !!argv.delete("--build")

    # `--tab NOM` : édite une tablature existante (cherchée dans `Session.song`) au
    # lieu du select initial de `tablator assistant`.
    tab_name = nil
    %w[--tab].each do |flag|
      if (i = argv.index(flag))
        tab_name = argv[i + 1]
        argv.delete_at(i + 1)
        argv.delete_at(i)
      end
    end

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

    # `--song TITRE` : contexte chanson pour CETTE commande SEULEMENT (recherche
    # intelligente comme `use song`, mais sans persistance — voir `Session.with_song`).
    song_opt = nil
    %w[--song].each do |flag|
      if (i = argv.index(flag))
        song_opt = argv[i + 1]
        argv.delete_at(i + 1)
        argv.delete_at(i)
      end
    end
    song_override = song_opt ? resolve_song_folder(song_opt) : nil

    command, arg1, arg2, arg3 = argv

    Session.with_song(song_override) do
    case command
    when "-h", "--help"
      puts colorize_help(USAGE)
    when "diags"
      puts raccourci(DiagsPage.build_and_open!)
    when "update"
      case arg1
      when "diags"
        created, skipped = GenerateChordDiagrams.run
        created.each { |c| puts "#{AnsiColors::SUCCESS}👍 #{raccourci(c[:path])}#{AnsiColors::RESET}" }
        skipped.each do |s|
          msg = s[:error] ? "#{s[:line]} — #{s[:error]}" : s[:line]
          puts "#{AnsiColors::ERROR}👎 #{raccourci(s[:schema_path])} : #{msg}#{AnsiColors::RESET}"
        end
        DiagsPage.build!
        puts "#{AnsiColors::SUCCESS}👍 #{Loc.get("diags_updated")}#{AnsiColors::RESET}"
      else
        abort unknown_command_message("update #{arg1}")
      end
    when "create"
      case arg1
      when "song"
        begin
          # Nouvelle chanson créée -> devient le contexte courant (Phil, 2026-08-26 :
          # bug constaté, l'ancien contexte `use song` restait en place).
          folder = SongCreator.run(arg2, arg3)
          Session.song = folder if folder.is_a?(String)
        rescue Interrupt
          puts
          puts Loc.get("song_creation_cancelled")
        end
      when "songbook", "sb"
        begin
          folder = SongbookCreator.run(arg2)
          Session.carnet = folder if folder.is_a?(String)
        rescue Interrupt
          puts
          puts Loc.get("song_creation_cancelled")
        end
      when "tab"
        # Seulement dans une chanson (Session.song), JAMAIS un carnet (Phil, 2026-08-26)
        # — `--song`/`use song` la fixent déjà avant d'arriver ici (`Session.with_song`).
        abort "aucune chanson de contexte pour create tab (use song ou --song)" unless Session.song

        begin
          # `arg2` : nom de la tablature à créer (".tab" ajouté si absent) — remplace le
          # "Titre :" normalement demandé à l'enregistrement, jamais redemandé si donné ici.
          TablatorAssistant.write_tablature(title: arg2&.sub(/\.tab\z/i, ""))
        rescue Interrupt
          puts
        end
      else
        abort unknown_command_message("create #{arg1}")
      end
    when "edit"
      case arg1
      when "chords"
        begin
          song_folder = resolve_song_folder(arg2 || Session.song)
          lyr_path = FileFinder.find(song_folder, :lyr)
          abort "aucun .lyr/.lyrics trouvé dans #{song_folder}" unless lyr_path

          ChordPlacer.run(lyr_path)
        rescue Interrupt
          puts
        end
        puts Loc.get("edition_cancelled")
      when "tab"
        begin
          tab_path = TablatorAssistant.resolve_tab_path(arg2)
          TablatorAssistant.write_tablature(edit_path: tab_path)
        rescue Interrupt
          puts
        end
      else
        abort unknown_command_message("edit #{arg1}")
      end
    when "song"
      case arg1
      when "id"
        begin
          song_folder = resolve_song_folder(arg2 || Session.song)
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
    when "manual", "manuel"
      manuel_dir = File.expand_path("../Manuel", __dir__)
      adoc_path = File.join(manuel_dir, "Manuel.adoc")
      html_path = File.join(manuel_dir, "Manuel.html")
      system("asciidoctor", adoc_path, "-o", html_path)
      system("open", html_path)

      if arg1
        needle = arg1.downcase
        matches = Dir.glob(File.join(manuel_dir, "**", "*.adoc")).flat_map do |f|
          File.readlines(f).each_with_index.filter_map do |line, i|
            "#{f}:#{i + 1}: #{line.strip}" if line.downcase.include?(needle)
          end
        end
        puts matches.empty? ? "rien trouvé pour « #{arg1} »" : matches.join("\n")
      end
    when "cover"
      begin
        case arg1
        when "dims"
          carnet_folder = resolve_carnet_folder(arg2 || Session.carnet)
          kdp = kdp_for_carnet(carnet_folder)
          print_cover_dims(kdp)
        when "idml", "modele"
          carnet_folder = resolve_carnet_folder(arg2 || Session.carnet)
          kdp = kdp_for_carnet(carnet_folder)
          infos_path = FileFinder.find(carnet_folder, :inf)
          conf = CarnetBuilder.parse_nested_infos(infos_path)
          entries = CarnetBuilder.tdm_entries(carnet_folder)
          slug = File.basename(carnet_folder).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
          out_dir = File.join(carnet_folder, "export", "cover")
          FileUtils.mkdir_p(out_dir)
          IdmlCoverBuilder.build(File.join(out_dir, "#{slug}-cover.idml"), conf: conf, entries: entries, carnet_folder: carnet_folder, kdp: kdp)
          puts "#{AnsiColors::SUCCESS}👍 Modèle IDML de couverture produit.#{AnsiColors::RESET}"
        else
          abort unknown_command_message("cover #{arg1}")
        end
      rescue Interrupt
        puts
      end
    when "tdm"
      begin
        carnet_folder = resolve_carnet_folder(arg1 || Session.carnet)
        tdm_path = FileFinder.find(carnet_folder, :tdm)
        abort "aucun fichier .tdm/.toc trouvé dans #{carnet_folder}" unless tdm_path

        system("open", "-a", AppConfig.user_song_editor, tdm_path)
      rescue Interrupt
        puts
      end
    when "list"
      case arg1
      when "songs"
        carnet_folder = Session.carnet || (CarnetBuilder.carnet_folder?(Dir.pwd) ? Dir.pwd : nil)
        abort "aucun carnet de contexte pour list songs (use songbook, ou dossier courant)" unless carnet_folder

        template = arg2 || "{title}"
        separator = (arg3 || "\\n").gsub('\\n', "\n")
        puts CarnetBuilder.list_songs(carnet_folder, template, separator)
      else
        abort unknown_command_message("list #{arg1}")
      end
    when "use"
      case arg1
      when "song", "s"
        Session.song = resolve_song_folder(arg2)
        puts format(Loc.get("use_song_set"), SongResolver.display_name(Session.song))
      when "songbook", "sb"
        Session.carnet = resolve_carnet_folder(arg2)
        puts format(Loc.get("use_carnet_set"), SongResolver.display_name(Session.carnet))
      else
        abort unknown_command_message("use #{arg1}")
      end
    when "tablator", "tab"
      case arg1
      when "assistant"
        begin
          TablatorAssistant.run(create: tab_create, build: tab_build, tab_name: tab_name)
        rescue Interrupt
          puts
        end
      else
        abort unknown_command_message("#{command} #{arg1}")
      end
    when "open"
      case arg1
      when "song", nil
        begin
          song_folder = resolve_song_folder(arg2 || Session.song)
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
          selected = TTY::Prompt.new.multi_select(blue(Loc.get("open_which_files")), choices, default: defaults, echo: false, show_help: false)
          files = selected - [:folder]
          system("open", "-a", AppConfig.user_song_editor, *files) unless files.empty?
          SongCreator.open_in_file_manager(song_folder) if selected.include?(:folder)
        rescue Interrupt
          puts
          puts Loc.get("edition_cancelled")
        end
      when "folder"
        context = resolve_open_context
        SongCreator.open_in_file_manager(context[:folder])
      when "lyrics"
        abort "aucune chanson sélectionnée (use song) — 'open lyrics' n'existe que pour les chansons" unless Session.song

        lyr_path = FileFinder.find(Session.song, :lyr) || propose_create_file(Session.song, "lyr")
        abort "aucun fichier .lyr/.lyrics trouvé dans #{Session.song}" unless lyr_path

        system("open", "-a", AppConfig.user_song_editor, lyr_path)
      when "infos"
        context = resolve_open_context
        inf_path = FileFinder.find(context[:folder], :inf) || propose_create_file(context[:folder], "infos")
        abort "aucun fichier .infos/.inf trouvé dans #{context[:folder]}" unless inf_path

        system("open", "-a", AppConfig.user_song_editor, inf_path)
      when "gabarit"
        context = resolve_open_context
        gab_path = FileFinder.find(context[:folder], :gab) || propose_create_file(context[:folder], "gab")
        abort "aucun fichier .gabarit/.gab trouvé dans #{context[:folder]}" unless gab_path

        system("open", "-a", AppConfig.user_song_editor, gab_path)
      when "pdf"
        context = resolve_open_context
        pdf_path = latest_pdf_path(context)
        abort "aucun PDF construit pour l'instant (build d'abord)" unless pdf_path

        system("open", pdf_path)
      else
        abort unknown_command_message("open #{arg1}")
      end
    when nil, ".", "build"
      if command == "build" && arg1 == "diag" && arg2
        begin
          DiagSchem.build_svg_from_schema(arg2)
          puts "#{AnsiColors::SUCCESS}👍 Diagramme produit.#{AnsiColors::RESET}"
        rescue SchemaInvalide => e
          abort e.message
        rescue Interrupt
          puts
        end
        return
      end

      if command == "build" && arg1 == "tab" && arg2
        begin
          song_folder = resolve_song_target(arg2)[:folder]
          tab_paths = Dir.glob(File.join(song_folder, "**", "*.tab"))
          if tab_paths.empty?
            puts Loc.get("tablator_no_tab_found")
          else
            tab_paths.each { |p| TablatorAssistant.render_tab_svg(p) }
          end
        rescue Interrupt
          puts
        end
        return
      end

      if command == "build" && arg1 == "cover"
        cover = true
        arg1 = nil
      end
      begin
        if command == "build" && arg1 == "song" && (arg2 || Session.song)
          title = arg2 || Session.song
          target = Dir.exist?(File.expand_path(title)) ? { kind: :song, folder: File.expand_path(title) } : resolve_song_target(title)
        elsif command == "build" && %w[songbook sb].include?(arg1) && (arg2 || Session.carnet)
          title = arg2 || Session.carnet
          target = Dir.exist?(File.expand_path(title)) ? { kind: :carnet, folder: File.expand_path(title) } : resolve_carnet_target(title)
        elsif command == "build" && arg1 && arg1 != "." && !Dir.exist?(File.expand_path(arg1))
          target = resolve_build_target(arg1)
        elsif command == "build" && arg1.nil? && (Session.song || Session.carnet)
          # `build` SANS argument : le contexte `use`/`--song` (REPL) l'EMPORTE TOUJOURS
          # sur le dossier courant (Phil, bug constaté 2026-08-25 — silencieusement
          # ignoré avant ce correctif).
          target = Session.song ? { kind: :song, folder: Session.song } : { kind: :carnet, folder: Session.carnet }
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
          CarnetBuilder.build(book_dir, only_song: File.basename(target[:folder]), debug_marks: debug_marks)
        elsif target[:kind] == :carnet
          CarnetBuilder.build(target[:folder], cover: cover, debug_marks: debug_marks)
        else
          pdf_path = CarnetBuilder.build_song(target[:folder])
          puts "#{AnsiColors::SUCCESS}👍 #{format(Loc.get("song_pdf_generated"), SongResolver.display_name(target[:folder]))}#{AnsiColors::RESET}"

          if Layout.log_conflict_count.to_i.positive?
            puts "#{AnsiColors::ERROR}#{format(Loc.get("song_build_conflicts_count"), Layout.log_conflict_count)}#{AnsiColors::RESET}"
            system("open", Layout.conflict_log_path) if TTY::Prompt.new.yes?(blue(Loc.get("song_build_open_conflicts_question")))
          end

          system("open", pdf_path) if TTY::Prompt.new.yes?(blue(Loc.get("song_build_open_pdf_question")))
        end
      rescue Interrupt
        puts
      rescue RuntimeError => e
        abort "Erreur : #{e.message}"
      end
    else
      abort unknown_command_message(command)
    end
    end
  end

  # KDP du DERNIER PDF déjà construit pour ce carnet (nombre de pages réel) — `cover
  # dims`/`cover idml` ont besoin du nombre de pages pour calculer le dos, mais ne
  # reconstruisent pas tout le carnet pour l'obtenir.
  def self.kdp_for_carnet(carnet_folder)
    infos_path = FileFinder.find(carnet_folder, :inf)
    abort "aucun fichier .infos/.inf trouvé dans #{carnet_folder}" unless infos_path

    conf = CarnetBuilder.parse_nested_infos(infos_path)
    page_size_in = conf.fetch("format") { AppConfig.get("format") }.split(/\s*x\s*/i).map { |v| v =~ /[a-z]/i ? AppConfig.length_pt(v) / AppConfig::IN_TO_PT : v.to_f }
    slug = File.basename(carnet_folder).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    latest_pdf = Dir.glob(File.join(carnet_folder, "export", "songbooks", "#{slug}-v*.pdf")).max_by { |f| f[/-v(\d+)\.pdf\z/, 1].to_i }
    abort "construisez d'abord le carnet (songbook build) pour en connaître le nombre de pages" unless latest_pdf

    page_count = CombinePDF.load(latest_pdf).pages.size
    KDP.new(page_count: page_count, trim_width: page_size_in[0], trim_height: page_size_in[1], paper: :white, bleed: false)
  end

  def self.print_cover_dims(kdp)
    bz = kdp.barcode_zone
    puts [
      "format papier (largeur x hauteur) : #{kdp.trim_width.round(3)} x #{kdp.trim_height.round(3)} in",
      "fond perdu (bleed) : #{KDP::BLEED_IN} in",
      "marge extérieure (pages intérieures) : #{kdp.outside_margin.round(3)} in",
      "marge de reliure (gouttière) : #{kdp.gutter_margin.round(3)} in",
      "largeur du dos : #{kdp.spine_width.round(3)} in",
      "couverture complète (largeur x hauteur) : #{kdp.cover_width.round(3)} x #{kdp.cover_height.round(3)} in",
      "marge de sécurité texte (plats) : #{kdp.cover_text_safe_margin.round(3)} in",
      "marge de sécurité texte (dos) : #{kdp.spine_text_safe_margin.round(3)} in",
      "zone code-barres : (#{bz[:x0].round(3)}, #{bz[:y0].round(3)}) à (#{bz[:x1].round(3)}, #{bz[:y1].round(3)}) in",
    ].join("\n")
  end

  def self.unknown_command_message(command)
    "commande inconnue : #{command} (aide : songbook -h)"
  end

  # Résolution de titre (chanson/carnet) — voir `SongResolver` (partagé avec
  # `TablatorAssistant`, extrait de là pour éviter un require circulaire).
  def self.resolve_song_folder(name)
    SongResolver.resolve_song_folder(name)
  end

  def self.resolve_carnet_folder(name)
    SongResolver.resolve_carnet_folder(name)
  end

  # Contexte courant pour `open folder`/`infos`/`gabarit`/`pdf` — chanson PRIORITAIRE
  # sur le carnet (même règle que `build` sans argument, Phil 2026-08-25). `open
  # lyrics`, lui, n'existe QUE pour une chanson (voir `open` ci-dessus), pas ici.
  def self.resolve_open_context
    if Session.song
      { kind: :song, folder: Session.song }
    elsif Session.carnet
      { kind: :carnet, folder: Session.carnet }
    else
      abort "aucun contexte (chanson ou carnet) sélectionné (use song/songbook)"
    end
  end

  # PDF déjà construit pour ce contexte — chanson : fichier unique (`build_song`,
  # jamais versionné). Carnet : versionné (`-v<N>.pdf`, `CarnetBuilder.build`), le
  # PLUS RÉCENT. `nil` si rien construit encore (jamais un chemin qui n'existe pas).
  def self.latest_pdf_path(context)
    if context[:kind] == :song
      Dir.glob(File.join(context[:folder], "export", "*.pdf")).first
    else
      Dir.glob(File.join(context[:folder], "export", "songbooks", "*-v*.pdf"))
        .max_by { |f| f[/-v(\d+)\.pdf\z/, 1].to_i }
    end
  end

  # Bleu pour toute question posée à l'user (même convention que `ChordPlacer.blue`/
  # `TablatorAssistant.blue`).
  def self.blue(text)
    "#{AnsiColors::BLUE}#{text}#{AnsiColors::RESET}"
  end

  # Chemin affiché à l'user : jamais le home complet en clair (Phil).
  def self.raccourci(chemin)
    chemin.sub(Dir.home, "~")
  end

  # Racine reprise du nom le PLUS UTILISÉ parmi les fichiers déjà présents (ex. "c.lyr"
  # + "c.infos" -> "c") — "c" par défaut si le dossier est vide (Phil, 2026-08-26,
  # valable pour n'importe quel type de fichier manquant).
  def self.most_common_root(folder)
    exts = FileFinder::EXTENSIONS.values.flatten
    roots = Dir.glob(File.join(folder, "*.{#{exts.join(',')}}")).map { |p| File.basename(p, ".*") }
    return "c" if roots.empty?

    roots.tally.max_by { |_, count| count }.first
  end

  # Fichier attendu absent (`open lyrics`/`infos`/`gabarit`...) : propose de le créer
  # (question bleue) plutôt que de simplement refuser — créé vide puis renvoyé (l'appel
  # `system("open", ...)` suivant l'ouvre normalement). `nil` si refusé.
  def self.propose_create_file(folder, ext)
    return nil unless TTY::Prompt.new.yes?(blue(format(Loc.get("create_missing_file_question"), ext)))

    path = File.join(folder, "#{most_common_root(folder)}.#{ext}")
    File.write(path, "")
    path
  end

  def self.select_song(message, songs)
    SongResolver.select_song(message, songs)
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
    choice = TTY::Prompt.new.select(blue(Loc.get("build_what_to_build")), [
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
