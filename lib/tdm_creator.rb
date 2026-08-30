# frozen_string_literal: true

require "io/console"
require "fileutils"
require_relative "ansi_colors"
require_relative "locale"
require_relative "session"
require_relative "app_config"
require_relative "carnet_builder"
require_relative "file_finder"
require_relative "song_resolver"
require_relative "songs_list"
require_relative "song_creator"

# `songbook create tdm`/`create toc` : construit (ou remplace) le `.tdm` d'un carnet —
# chanson de contexte/`--sb TITRE` ignorée (jamais pertinente ici), carnet demandé par
# nom sinon. Un nom sans correspondance n'est PAS une erreur : le carnet est à créer,
# confirmé juste avant l'écriture (Phil, 2026-08-30).
module TdmCreator
  extend AnsiColors

  def self.run(carnet_opt: nil)
    carnet_folder = if Session.carnet
      Session.carnet
    else
      name = carnet_opt || colored_prompt.ask(blue(Loc.get("tdm_carnet_name_question"))).to_s.strip
      abort "aucun nom donné" if name.to_s.strip.empty?

      resolve_or_create_carnet_folder(name)
    end

    chosen = pick_songs(SongsList.sort(SongsList.entries, "alpha"))

    unless Dir.exist?(carnet_folder)
      return unless colored_prompt.yes?(blue(format(Loc.get("tdm_create_carnet_question"), File.basename(carnet_folder))))

      FileUtils.mkdir_p(carnet_folder)
    end

    tdm_path = FileFinder.find(carnet_folder, :tdm) || File.join(carnet_folder, "c.tdm")
    File.write(tdm_path, chosen.map { |e| "- #{e[:infos]["id"]}" }.join("\n") << "\n")
    Session.carnet = carnet_folder
    puts success("👍 #{Loc.get("tdm_created")}")
    SongCreator.open_in_file_manager(carnet_folder) if colored_prompt.yes?(blue(Loc.get("tdm_open_question")))
  end

  # Pendant de `SongResolver.resolve_carnet_folder`, mais un nom sans correspondance ne
  # fait PAS `abort` — le carnet est simplement à créer (dossier pas encore présent).
  def self.resolve_or_create_carnet_folder(name)
    return File.expand_path(name) if Dir.exist?(File.expand_path(name))

    songbooks_dir = AppConfig.songbooks_dir
    matches = CarnetBuilder.find_carnet_by_title(songbooks_dir, name)
    return matches.first[:folder] if matches.size == 1
    return SongResolver.select_song(nil, matches) if matches.size > 1

    File.join(songbooks_dir, name)
  end

  # Liste UNIQUE, toujours la même (`entries`, jamais amputée) — chaque chanson porte
  # une coche (☑/☐, même largeur pour garder les titres alignés, Phil 2026-08-30) : la
  # choisir bascule son état (coché -> sort de la tdm, décoché -> y entre). Panneau FIXE
  # (nombre + titres choisis) réaffiché à chaque tour au-dessus du picker.
  # `TTY::Prompt#select(filter: true)` REPART TOUJOURS filtre vide à chaque appel
  # (`@filter = []` fixe dans `List#initialize`, gem tty-prompt, rien pour le
  # pré-remplir) — impossible d'avoir un filtre qui PERSISTE d'une sélection à l'autre
  # avec cet outil. Widget maison à la place (Phil, 2026-08-30) : lecture clavier
  # caractère par caractère (même principe que `ChordPlacer`/`TablatorAssistant`),
  # `filter_text` jamais réinitialisé entre deux choix — SEULE la touche Entrée sur
  # "Terminé" (position 0) sort de la boucle.
  def self.pick_songs(entries)
    label = ->(e) { e[:infos]["performer"].to_s.strip.empty? ? e[:infos]["title"].to_s : "#{e[:infos]["title"]} (#{e[:infos]["performer"]})" }
    chosen = []
    filter_text = +""
    highlight = 0

    render = lambda do
      matching = entries.select { |e| label.call(e).downcase.include?(filter_text.downcase) }
      highlight = highlight.clamp(0, matching.size)
      rows = ($stdout.winsize[0] rescue 24) || 24

      system("clear")
      puts blue(format(Loc.get("tdm_chosen_count"), chosen.size))
      # Panneau des chansons choisies : max 5 titres affichés (jamais lui qui doit
      # manger toute la hauteur du terminal) — le reste résumé en un compte.
      chosen.first(5).each { |e| puts "  - #{e[:infos]["title"]}" }
      puts gray(format(Loc.get("tdm_chosen_more"), chosen.size - 5)) if chosen.size > 5
      puts
      question = blue(Loc.get("tdm_pick_songs_question"))
      question += " #{gray("(#{filter_text})")}" unless filter_text.empty?
      puts question
      puts highlight.zero? ? blue("‣ #{Loc.get("tdm_done_option")}") : "  #{Loc.get("tdm_done_option")}"

      # Fenêtre glissante sur `matching` (jamais tout affiché d'un coup — débordait du
      # terminal, header/curseur poussés hors écran, Phil 2026-08-30, capture d'écran)
      # — reste centrée sur l'item survolé.
      reserved_rows = 6 + [chosen.size, 5].min
      window = [rows - reserved_rows, 3].max
      song_idx = highlight.zero? ? 0 : highlight - 1
      start = [[song_idx - window + 1, 0].max, [matching.size - window, 0].max].min
      visible = matching[start, window] || []

      puts gray("  ▲") if start.positive?
      visible.each_with_index do |e, i|
        idx = start + i
        line = "#{chosen.include?(e) ? "☑" : "☐"} #{label.call(e)}"
        puts highlight == idx + 1 ? blue("‣ #{line}") : "  #{line}"
      end
      puts gray("  ▼") if (start + visible.size) < matching.size
      matching
    end

    $stdin.raw(intr: true) do
      loop do
        matching = render.call
        key = $stdin.getc
        case key
        when "\r", "\n"
          break if highlight.zero?

          picked = matching[highlight - 1]
          chosen.include?(picked) ? chosen.delete(picked) : chosen << picked
        when "\x7F", "\b"
          filter_text = filter_text[0..-2] unless filter_text.empty?
        when "\e"
          seq = key + $stdin.getc
          if seq[1] == "["
            seq += $stdin.getc while seq[-1] !~ /[A-Za-z~]/
            case seq
            when "\e[A" then highlight -= 1
            when "\e[B" then highlight += 1
            end
          end
        else
          filter_text << key if key.match?(/\A[[:print:]]\z/)
        end
      end
    end
    chosen
  end
end
