# frozen_string_literal: true

require "io/console"
require "fileutils"
require "yaml"
require "tty-prompt"
require_relative "locale"
require_relative "session"
require_relative "song_resolver"
require_relative "carnet_builder"
require_relative "ansi_colors"
require_relative "../tools/tablator/tablator"

# `songbook tablator assistant` / `songbook tab assistant` : assistant interactif pour
# la production de tablatures (outil séparé `tools/tablator/tablator.rb`, pas de
# dépendance ici vers `CarnetBuilder`/`CLI`).
module TablatorAssistant
  extend AnsiColors

  # `create:`/`build:` (`--create`/`--build`) zappent le select initial. `tab_name:`
  # (`--tab NOM`) va direct en édition d'une tablature existante (cherchée dans la
  # chanson de contexte, `Session.song`).
  def self.run(create: false, build: false, tab_name: nil)
    return write_tablature(edit_path: resolve_tab_path(tab_name)) if tab_name

    choice =
      if create then :write
      elsif build then :svg
      else
        colored_prompt.select(blue(Loc.get("tablator_assistant_question")), [
          { name: Loc.get("tablator_choice_svg"), value: :svg },
          { name: Loc.get("tablator_choice_write"), value: :write },
        ], show_help: false)
      end

    case choice
    when :svg
      produce_svg
    when :write
      write_tablature
    end
  end

  # Chanson demandée (contexte `use song ...` du REPL en priorité, sinon liste
  # filtrable de toutes les chansons) -> TOUTES ses tablatures (`.tab`, n'importe où
  # dans le dossier de la chanson, voir Manuel/song/tablas-et-scores.adoc) rendues en SVG.
  def self.produce_svg
    song_folder = Session.song || SongResolver.resolve_song_folder(nil)
    tab_paths = Dir.glob(File.join(song_folder, "**", "*.tab"))

    if tab_paths.empty?
      puts Loc.get("tablator_no_tab_found")
      return
    end

    tab_paths.each { |tab_path| render_tab_svg(tab_path) }
  end

  # `out_base:` : base de sortie (`.svg`/`.ly`) si différente de `tab_path` sans son
  # extension — cas du fichier provisoire caché (`s`, voir `write_tablature`), qui doit
  # produire le SVG sous le nom NORMAL, pas caché.
  def self.render_tab_svg(tab_path, out_base: nil)
    content = File.read(tab_path)
    result = Tablator.render_tab_svg(content, measures_per_line: 999).first
    out_base ||= tab_path.sub(/\.tab\z/, "")
    File.write("#{out_base}.svg", result[:svg])
    puts success("👍 #{Loc.get('tablator_svg_produced')}")
  rescue Tablator::ParseError => e
    warn "#{tab_path} : #{e.message}"
  end

  # `name` : nom APPROXIMATIF, même recherche progressive que chanson/carnet (Phil,
  # 2026-08-26) — 1) préfixe/mots dans l'ordre (`CarnetBuilder.prefix_match?`/
  # `words_match?`) ; 1 seul résultat -> repris direct, plusieurs -> à choisir ; 2) rien
  # à l'étape 1 -> repli flou (distance de Levenshtein, même seuil que
  # `fuzzy_find_songs`). `name` `nil` : liste TOUTES les tablatures trouvées, à choisir
  # (`edit tab` sans argument).
  def self.resolve_tab_path(name)
    song_folder = Session.song
    abort "aucune chanson de contexte pour --tab (--song ou use song)" unless song_folder

    candidates = Dir.glob(File.join(song_folder, "**", "*.tab"))
    abort "aucune tablature (.tab) trouvée dans cette chanson" if candidates.empty?

    return select_tab(candidates, Loc.get("tablator_which_one")) if name.nil?

    target = CarnetBuilder.slugify(name)
    target_words = target.split("-").reject(&:empty?)
    matches = candidates.select do |p|
      candidate = CarnetBuilder.slugify(File.basename(p, ".tab"))
      CarnetBuilder.prefix_match?(target, candidate) || CarnetBuilder.words_match?(target_words, candidate)
    end
    return matches.first if matches.size == 1
    return select_tab(matches, Loc.get("tablator_which_one")) if matches.size > 1

    threshold = [2, (target.length * 0.35).round].max
    fuzzy = candidates
      .map { |p| [p, CarnetBuilder.levenshtein(target, CarnetBuilder.slugify(File.basename(p, ".tab")))] }
      .select { |_, distance| distance <= threshold }
      .sort_by { |_, distance| distance }
      .first(5)
      .map(&:first)
    abort "tablature introuvable : #{name}" if fuzzy.empty?

    select_tab(fuzzy, Loc.get("song_not_found_did_you_mean"))
  end

  def self.select_tab(paths, message)
    songs = paths.map { |p| { name: File.basename(p, ".tab"), title: nil, folder: p } }
    SongResolver.select_song(message, songs)
  end

  # Nom des cordes à vide (accordage standard EADGBE), 1 = aiguë (mi4) .. 6 = grave (mi2)
  # — mêmes numéros que `Tablator::OPEN_STRING_MIDI`. "E" pour les deux mi (Phil : pas
  # de "e" minuscule), distingués par leur position (haut/bas) dans la grille.
  STRING_LABELS = %w[E B G D A E].freeze
  COL_WIDTH = 2
  MAX_CASE = 20
  ROW_MARGIN = 3 # label (1 car) + 2 "|"
  DEFAULT_UNIT = "croche"
  # Durée LilyPond (dénominateur) associée à chaque valeur rythmique choisissable
  # dans la config (touche `c`) — s'applique à TOUTES les notes saisies (pas de
  # rythme par note dans cet éditeur).
  DURATIONS = { "noire" => 4, "croche" => 8, "double-croche" => 16, "triple-croche" => 32 }.freeze

  # Rangée des chiffres d'un clavier AZERTY SANS Shift (Phil, confirmé 2026-08-26 —
  # corrige "-"=6/"_"=8, faux, décidés sans concertation) -> chiffre équivalent. Même
  # table que `ChordPlacer::AZERTY_DIGITS`.
  AZERTY_DIGITS = {
    "&" => "1", "é" => "2", "\"" => "3", "'" => "4", "(" => "5",
    "§" => "6", "è" => "7", "!" => "8", "ç" => "9", "à" => "0",
  }.freeze

  KEY_SEQUENCES = {
    "\e[A" => :up, "\e[B" => :down, "\e[C" => :right, "\e[D" => :left,
    "\e[1;2C" => :shift_right, "\e[1;2D" => :shift_left,
  }.freeze

  # Cellule de la grille : case (fret) + doigté main droite (p/i/m/a/c, `rh`) + doigté
  # main gauche (chiffre, `lh`) — Phil, 2026-08-26. `rh`/`lh` restent `nil` tant que non
  # précisés (une cellule "0" seule reste valide, sans aucun doigté).
  Cell = Struct.new(:kase, :rh, :lh)

  # Lettres de doigté main droite (Manuel/tools/tablator.adoc) — "c" (chiquito,
  # auriculaire) entre EN COLLISION avec la commande "config" existante ; résolu par
  # contexte (voir boucle de saisie : seulement pendant la composition d'une note).
  RH_FINGERS = %w[p i m a c].freeze
  # "+" : saisie grille pour "pas de doigté main droite", passe direct à la main
  # gauche (Phil : "0+2" = case 0, pas de main droite, 2e doigt main gauche).
  RH_SKIP = "+"
  BAR_CHARS = %w[| : .].freeze

  # Éditeur console : curseur déplacé ←/→ et ↑/↓, chiffres 0-9 (case, 2 chiffres max,
  # clavier AZERTY sans Shift accepté), `x` efface, Shift+←/→ repousse tout ce qui
  # suit le curseur (Shift+← écrase la colonne du curseur, le reste se décale dedans),
  # `c` ouvre la config, `s` produit le SVG SANS quitter (état courant écrit dans un
  # fichier `.tab` PROVISOIRE CACHÉ `.~<nom>.tab`, le SVG produit porte lui le nom
  # normal), `q` termine et enregistre, Ctrl+C annule. Le fichier provisoire est
  # TOUJOURS détruit en sortie (`ensure`, y compris sur Ctrl+C, Phil). `edit_path:` :
  # tablature existante chargée dans la grille (frontmatter -> `title`/`unit`/
  # `metrique`, corps -> matrice), réenregistrée au même endroit (sinon nouveau
  # fichier, titre demandé). `title:` (`create tab NOM`, Phil 2026-08-26) : pré-répond
  # à ce "Titre :" pour une NOUVELLE tablature — jamais redemandé si déjà donné.
  def self.write_tablature(edit_path: nil, title: nil)
    meta = {}
    tokens_in = []
    if edit_path
      meta, body = Tablator.parse_frontmatter(File.read(edit_path))
      tokens_in = Tablator.tokenize(body)
    elsif title
      meta["title"] = title
    end
    unit = meta["unit"] || DEFAULT_UNIT
    metrique = meta["metrique"]
    temp_path = nil

    console_width = ($stdin.winsize[1] - ROW_MARGIN) / COL_WIDTH
    width = [console_width, columns_needed(tokens_in, unit)].max
    matrix, bars, rests = matrix_from_tokens(tokens_in, width, unit)
    string = 1
    col = 0
    # Composition en cours (une note "0p2"/"0+2", OU une barre "|" puis "." -> "|.") —
    # `nil` tant qu'aucune saisie n'est en cours (Phil, 2026-08-26). Toute touche NON
    # reconnue par la composition active la CLÔT (une saisie partielle, ex. "0p" sans
    # main gauche, reste un résultat valide) puis s'exécute normalement — voir fin de
    # boucle.
    composing = nil
    # "q" demande confirmation avant d'enregistrer (question bleue, cohérence avec les
    # autres éditeurs de l'app) ; Entrée enregistre directement, sans redemander (Phil,
    # 2026-08-26).
    ask_before_save = false
    # Valide une barre en cours de composition (si `buffer` forme une barre reconnue,
    # sinon abandonnée en silence) — appelé à CHAQUE sortie de la composition, y
    # compris "q"/Entrée (`break` saute le reste de la boucle, bug constaté 2026-08-26 :
    # une barre commencée juste avant de quitter disparaissait silencieusement).
    commit_bar = lambda do
      if composing && composing[:kind] == :bar
        if Tablator::BAR_RE.match?(composing[:buffer])
          bars[composing[:col]] = composing[:buffer]
        else
          bars.delete(composing[:col])
        end
      end
      composing = nil
    end

    begin
      begin
        $stdin.raw(intr: true) do
          loop do
            draw_grid(matrix, bars, rests, string, col, unit)
            key = read_key
            key = AZERTY_DIGITS.fetch(key, key) if key.is_a?(String)
            # "B" (Phil, 2026-08-27) : remplace "|" comme touche de saisie de barre
            # simple — "|" en direct nécessite Alt+Maj+L (AZERTY Mac), combinaison
            # invisible à l'écran tant que la barre n'est pas committée. Traduit AVANT
            # le `case` pour réutiliser tel quel tout le mécanisme de composition
            # (`BAR_CHARS`, `BAR_RE`) qui raisonne en "|"/":"/".".
            key = "|" if key == "B"

            case key
            when :up then string = [string - 1, 1].max
            when :down then string = [string + 1, 6].min
            when :left then col = [col - 1, 0].max
            when :right then col = [col + 1, width - 1].min
            # Mêmes lettres que "début/fin de vers" dans l'édition des accords
            # (`ChordPlacer` : "J"/"L", Phil, 2026-08-27).
            when "J" then col = 0
            when "L"
              col = (0...width).reverse_each.find { |c| bars[c] || (1..6).any? { |s| matrix[s - 1][c] } } || 0
            when :shift_right
              shift_right!(matrix, bars, rests, col, width)
            when :shift_left
              shift_left!(matrix, bars, rests, col)
            when "x"
              matrix[string - 1][col] = nil
              bars.delete(col)
              rests.delete(col)
            # Doigté main droite (ou "+" = aucun) : SEULEMENT juste après la/les case(s)
            # d'une note en cours (sinon "c" reprend son sens de commande "config").
            when ->(k) { composing && composing[:kind] == :note && composing[:stage] == :case && k.is_a?(String) && (RH_FINGERS.include?(k) || k == RH_SKIP) }
              matrix[composing[:string] - 1][composing[:col]].rh = key unless key == RH_SKIP
              composing[:stage] = :rh_done
              next
            # Doigté main gauche : juste après le doigté droit (ou son "+").
            when ->(k) { composing && composing[:kind] == :note && composing[:stage] == :rh_done && k.is_a?(String) && k.match?(/\A\d\z/) }
              matrix[composing[:string] - 1][composing[:col]].lh = key
              composing = nil
              next
            # Barre en cours de composition ("|" puis "." -> "|.", etc.).
            when ->(k) { composing && composing[:kind] == :bar && k.is_a?(String) && BAR_CHARS.include?(k) }
              composing[:buffer] += key
              bars[composing[:col]] = composing[:buffer]
              next
            when "c"
              unit, metrique = open_config(unit, metrique)
            # "S" (Phil, 2026-08-28) : majuscule pour libérer "s" minuscule (silence
            # invisible, voir plus bas) — même logique que "B"/barre : une lettre à plat
            # ne peut porter qu'un seul sens.
            when "S"
              temp_path, out_base = tab_paths_for(meta, edit_path)
              meta["unit"] = unit
              meta["metrique"] = metrique if metrique
              File.write(temp_path, serialize(meta, matrix_to_tokens(matrix, unit, bars: bars, rests: rests)))
              render_tab_svg(temp_path, out_base: out_base)
            # Silence explicite : "r" visible, "s" invisible ("skip") — posé tout de
            # suite comme une note, la position de l'événement suivant détermine sa
            # durée (Phil, 2026-08-28 : "on a la chance d'être avec un instrument
            # unique, profitons-en"). Efface tout ce qu'il y avait sur les 6 cordes à
            # cette colonne (un silence est global, pas par corde) et toute barre
            # posée là (une colonne ne porte qu'UN seul type de repère).
            when "r", "s"
              (1..6).each { |s| matrix[s - 1][col] = nil }
              bars.delete(col)
              rests[col] = key
            when "q", "Q"
              ask_before_save = true
              commit_bar.call
              break
            when "\r", "\n"
              commit_bar.call
              break
            when /\A\d\z/
              if composing && composing[:kind] == :note && composing[:stage] == :case && composing[:string] == string && composing[:col] == col
                cell = matrix[string - 1][col]
                candidate = "#{cell.kase}#{key}".to_i
                cell.kase = candidate <= MAX_CASE ? candidate : key.to_i
              else
                matrix[string - 1][col] = Cell.new(key.to_i, nil, nil)
                rests.delete(col)
                composing = { kind: :note, stage: :case, string: string, col: col }
              end
              next
            when *BAR_CHARS
              composing = { kind: :bar, col: col, buffer: key }
              bars[col] = key
              rests.delete(col)
              next
            end

            # Toute touche qui arrive ici a été traitée normalement (pas de `next`
            # ci-dessus) : clôt une composition de barre en cours.
            commit_bar.call
          end
        end
      rescue Interrupt
        puts
        puts Loc.get("build_cancelled")
        return
      end

      tokens = matrix_to_tokens(matrix, unit, bars: bars, rests: rests)
      if tokens.empty?
        puts Loc.get("tablator_write_empty")
        return
      end

      return if ask_before_save && !colored_prompt.yes?(blue(Loc.get("save_changes_question")), default: false)

      meta["metrique"] = metrique if metrique
      out_path = save_tablature(tokens, meta, unit, edit_path)
      puts success("👍 #{Loc.get("tablator_write_saved")}")

      return unless colored_prompt.yes?(blue(Loc.get("tablator_build_now_question")))

      render_tab_svg(out_path)
    ensure
      File.delete(temp_path) if temp_path && File.exist?(temp_path)
    end
  end

  # Chemins pour `edit_path` (dossier + racine du nom, SANS l'extension) — mêmes pour
  # le fichier provisoire caché (`s`) et le fichier final (`q`) : `[".~<base>.tab"
  # (dossier), "<dossier>/<base>" (out_base, pour SVG/.ly)]`. Titre demandé UNE FOIS
  # (mémorisé dans `meta`) si nouvelle tablature (pas d'`edit_path`).
  def self.tab_paths_for(meta, edit_path)
    if edit_path
      dir = File.dirname(edit_path)
      base = File.basename(edit_path, ".tab")
    else
      meta["title"] ||= colored_prompt.ask(blue("Titre :")) { |q| q.required true }
      dir = Session.song ? File.join(Session.song, "scores") : Dir.pwd
      FileUtils.mkdir_p(dir)
      base = CarnetBuilder.slugify(meta["title"])
    end
    [File.join(dir, ".~#{base}.tab"), File.join(dir, base)]
  end

  def self.serialize(meta, tokens)
    "#{YAML.dump(meta)}---\n#{tokens.join(' ')}\n"
  end

  # Décale tout ce qui suit (et inclut) `col` d'une colonne — `→` insère une colonne
  # vide en `col` (la dernière colonne tombe hors grille), `←` supprime la colonne
  # `col` (écrase donc son contenu par ce qui suit) et ajoute une colonne vide en fin.
  # `bars`/`rests` (barres de mesure, silences explicites — dicts `colonne => ...`)
  # décalés PAREIL que la matrice de notes (bug constaté, Phil : Maj+←/→ ne bougeait
  # QUE les notes, laissant barres et silences sur place — décalage incohérent).
  def self.shift_right!(matrix, bars, rests, col, width)
    matrix.each do |row|
      row.insert(col, nil)
      row.pop
    end
    shift_hash_right!(bars, col, width)
    shift_hash_right!(rests, col, width)
  end

  def self.shift_left!(matrix, bars, rests, col)
    matrix.each do |row|
      row.delete_at(col)
      row.push(nil)
    end
    shift_hash_left!(bars, col)
    shift_hash_left!(rests, col)
  end

  # Repère (barre/silence) déjà en `col` ou après -> `col + 1`, la dernière tombe hors
  # grille (`width`, même limite que la matrice) — ordre DÉCROISSANT indispensable
  # (sinon une valeur tout juste déplacée se ferait réécrire par la suivante).
  def self.shift_hash_right!(hash, col, width)
    hash.keys.sort.reverse_each do |k|
      next if k < col

      val = hash.delete(k)
      hash[k + 1] = val if k + 1 < width
    end
  end

  # `col` écrasée (son repère éventuel disparaît, comme la matrice), tout repère
  # APRÈS `col` recule d'une colonne — ordre CROISSANT indispensable (symétrique de
  # `shift_hash_right!`).
  def self.shift_hash_left!(hash, col)
    hash.delete(col)
    hash.keys.sort.each do |k|
      next unless k > col

      hash[k - 1] = hash.delete(k)
    end
  end

  def self.open_config(unit, metrique)
    choice = colored_prompt.select(blue(Loc.get("tablator_config_menu")), [
      { name: Loc.get("tablator_config_unit"), value: :unit },
      { name: Loc.get("tablator_config_metrique"), value: :metrique },
    ], show_help: false)

    case choice
    when :unit then [choose_unit(unit), metrique]
    when :metrique then [unit, ask_metrique]
    end
  end

  def self.choose_unit(current)
    choices = DURATIONS.keys
    colored_prompt.select(blue(Loc.get("tablator_config_question")), choices, default: choices.index(current).to_i + 1, show_help: false)
  end

  def self.ask_metrique
    prompt = colored_prompt
    haut = prompt.ask(blue(Loc.get("tablator_metrique_top"))) { |q| q.validate(/\A\d+\z/) }
    bas = prompt.ask(blue(Loc.get("tablator_metrique_bottom"))) { |q| q.validate(/\A\d+\z/) }
    "#{haut}/#{bas}"
  end

  # Une barre traverse TOUTE la tablature (Phil, 2026-08-27) : dessinée sur les 6
  # cordes à sa colonne, pas seulement sur une ligne à part sous la grille.
  def self.draw_grid(matrix, bars, rests, cur_string, cur_col, unit)
    print "\e[2J\e[H"
    (1..6).each do |string|
      row = matrix[string - 1].each_with_index.map do |cell, col|
        text = if bars[col]
                 bars[col].ljust(COL_WIDTH)
               elsif rests[col]
                 # Silence global (6 cordes) : lettre R/S en MAJUSCULE seulement sur la
                 # 3e ligne (Phil, 2026-08-28), les 5 autres portent un guillemet '"'
                 # (renvoi, comme un "idem" typographique) plutôt que répéter la lettre.
                 (string == 3 ? rests[col].upcase : '"').ljust(COL_WIDTH)
               elsif cell.nil?
                 "-" * COL_WIDTH
               else
                 "#{cell.kase}#{cell.rh}#{cell.lh}".ljust(COL_WIDTH, "-")
               end
        string == cur_string && col == cur_col ? "\e[7m#{text}\e[0m" : text
      end.join
      puts "#{STRING_LABELS[string - 1]}|#{row}|"
    end
    puts gray(format(Loc.get('tablator_write_help'), unit))
  end

  # Séquence CSI (`ESC [ ... lettre-finale`) lue en entier (longueur variable, ex.
  # `ESC [ 1 ; 2 C` pour Shift+→) — lire un nombre fixe d'octets après ESC cassait sur
  # ces séquences plus longues que les flèches simples. Toute séquence ESC qui n'est
  # PAS une CSI (2e octet ≠ "[", ex. Option/Alt+lettre envoyé en "Meta" par le terminal
  # — Terminal.app, réglage "Use Option as Meta key") est renvoyée TELLE QUELLE dès 2
  # octets, SANS attendre un 3e octet qui n'arrivera jamais (Phil, 2026-08-27 : bug
  # constaté, la frappe suivante était alors avalée comme si elle appartenait à cette
  # séquence).
  def self.read_key
    c = $stdin.getc
    return c unless c == "\e"

    seq = c + $stdin.getc
    return seq unless seq[1] == "["

    loop do
      ch = $stdin.getc
      seq += ch
      break if ch =~ /[A-Za-z~]/
    end
    KEY_SEQUENCES.fetch(seq, seq)
  end

  # Grille -> tokens Tablator (voir `tools/tablator/tablator.rb`) : une colonne sans
  # aucune corde jouée est ignorée EN TANT QUE COLONNE, mais PAS musicalement (Phil,
  # 2026-08-25 : "sinon tout est faux") — un "trou" (colonnes vides) après une note
  # PROLONGE cette note : sa durée réelle = span de colonnes (elle + le trou) jusqu'à
  # l'événement suivant OU une barre (`bars`, Phil 2026-08-26 : "|." doit arrêter la
  # DERNIÈRE note, pas `width` — dépendait de la largeur du terminal, arbitraire), ou
  # la fin à défaut des deux, converti en durée LilyPond pointée via `duration_for`.
  # Plusieurs cordes sur la même colonne -> accord `<corde:case ...>` (doigté ignoré
  # pour un accord, hors scope). Un trou AVANT la première note (Phil) compte aussi
  # (placement des barres) mais n'est PAS marqué par défaut (levée) -> silence
  # INVISIBLE (`sN`, "skip" LilyPond), jamais supprimé silencieusement.
  def self.matrix_to_tokens(matrix, unit, bars: {}, rests: {})
    width = matrix.first.length
    unit_denominator = DURATIONS.fetch(unit)
    events = (0...width).filter_map do |col|
      notes = (1..6).filter_map { |string| matrix[string - 1][col] && [string, matrix[string - 1][col]] }
      [col, notes] unless notes.empty?
    end
    return [] if events.empty? && bars.empty? && rests.empty?

    notes_by_col = events.to_h
    bar_cols = bars.keys.sort
    stops = (notes_by_col.keys + bar_cols + rests.keys).uniq.sort

    # Une barre interrompt la tenue implicite d'une note (qui, sinon, "sonne" jusqu'au
    # prochain repère) : dès `col` 0 et après chaque barre, tout écart avant le prochain
    # repère (note, silence ou barre suivante) doit être écrit comme silence invisible
    # ("s<durée>"), sinon une mesure sans note posée disparaît purement et simplement à
    # l'enregistrement (bug constaté, Phil, 2026-08-28 : "une barre définit une longueur
    # de mesure, elle doit être remplie de silence"). Pas de comblement en fin de grille
    # SANS barre : la largeur de la grille est arbitraire (taille du terminal), pas une
    # fin de mesure. Un silence EXPLICITE ("r"/"s" posé par l'utilisateur, Phil,
    # 2026-08-28) se comporte comme une note : sa durée = span jusqu'au prochain repère
    # (même logique, "c'est la position de l'événement suivant qui détermine la durée").
    tokens = []
    cursor = 0
    pending_reset = true
    stops.each do |col|
      if bars[col] && !notes_by_col[col] && !rests[col]
        tokens << "s#{duration_for(col - cursor, unit_denominator)}" if pending_reset && col > cursor
        tokens << bars[col]
        cursor = col + 1
        pending_reset = true
        next
      end

      tokens << "s#{duration_for(col - cursor, unit_denominator)}" if pending_reset && col > cursor
      next_boundary = stops.find { |b| b > col } || width
      duree = duration_for(next_boundary - col, unit_denominator)
      tokens <<
        if (notes = notes_by_col[col])
          if notes.size == 1
            string, cell = notes.first
            suffix = cell.rh || cell.lh ? "-#{cell.rh}#{cell.lh}" : ""
            "#{string}#{cell.kase}/#{duree}#{suffix}"
          else
            "<#{notes.map { |s, c| "#{s}#{c.kase}" }.join(' ')}>/#{duree}"
          end
        else
          "#{rests[col]}#{duree}"
        end
      cursor = next_boundary
      pending_reset = false
    end
    tokens
  end

  # Durée LilyPond (dénominateur + points) pour un span de `span` colonnes de valeur de
  # base `unit_denominator` (ex. span=2, unit_denominator=8 [croche] -> "4" [noire] ;
  # span=3 -> "4." [noire pointée] ; span=7 -> "2.." [blanche doublement pointée]).
  # Un span SANS représentation par points seuls (aurait besoin de liaisons `~`, non
  # gérées par le format simplifié de `tools/tablator/tablator.rb`) retombe sur la
  # durée de base SANS fusion — limite connue, pas un silence perdu par accident mais
  # par absence de support des liaisons dans le format.
  def self.duration_for(span, unit_denominator)
    (0..3).each do |dots|
      denom_calc = span * (2**dots)
      numerator = unit_denominator * ((2**(dots + 1)) - 1)
      next unless (numerator % denom_calc).zero?

      base_denom = numerator / denom_calc
      return "#{base_denom}#{'.' * dots}" if base_denom.positive? && (base_denom & (base_denom - 1)).zero?
    end
    unit_denominator.to_s
  end

  # Pendant inverse de `matrix_to_tokens` (édition d'une tablature existante) : la
  # durée de chaque token (dénominateur + points éventuels) est reconvertie en span de
  # colonnes SELON `unit` COURANT (peut différer de celui utilisé à la création si la
  # config a changé) — les colonnes vides du span sont laissées vides, reconstituant
  # visuellement le "trou". Une barre (`Tablator::BAR_RE`, les 6 formes) occupe 1
  # colonne, sans note. Nombre de colonnes qu'occuperont `tokens` une fois rechargés
  # (span par span, voir `span_from_duration`) — utilisé pour dimensionner la grille au
  # chargement d'une tablature existante (`--tab`) si elle dépasse la largeur console.
  def self.columns_needed(tokens, unit)
    unit_denominator = DURATIONS.fetch(unit)
    col = 0
    tokens.each do |token|
      if Tablator::BAR_RE.match?(token)
        col += 1
        next
      end

      if (rm = Tablator::REST_RE.match(token))
        col += span_from_duration(rm[2], unit_denominator)
        next
      end

      duree =
        if (m = Tablator::CHORD_RE.match(token)) then m[3]
        elsif (m = Tablator::CORDE_CASE_RE.match(token)) then m[3]
        end
      next unless m

      col += span_from_duration(duree, unit_denominator)
    end
    col
  end

  # Renvoie `[matrix, bars, rests]` — `bars` : `{colonne => "|."/"||"/...}`, `rests` :
  # `{colonne => "r"/"s"}` (silence explicite, Phil, 2026-08-28 — voir `matrix_to_tokens`).
  # Le doigté ("-<main droite><main gauche>", groupes 4/5 de `Tablator::CORDE_CASE_RE`)
  # est reconstruit dans la `Cell` pour une note simple (jamais dans un accord `<...>`,
  # hors scope).
  def self.matrix_from_tokens(tokens, width, unit)
    matrix = Array.new(6) { Array.new(width) }
    bars = {}
    rests = {}
    unit_denominator = DURATIONS.fetch(unit)
    col = 0
    tokens.each do |token|
      break if col >= width

      if Tablator::BAR_RE.match?(token)
        bars[col] = token
        next
      end

      if (rm = Tablator::REST_RE.match(token))
        rests[col] = rm[1]
        col += span_from_duration(rm[2], unit_denominator)
        next
      end

      duree =
        if (m = Tablator::CHORD_RE.match(token))
          m[2].split(/\s+/).each do |pair|
            cm = Tablator::CORDE_CASE_RE.match(pair)
            matrix[cm[1].to_i - 1][col] = Cell.new(cm[2].to_i, nil, nil) if cm
          end
          m[3]
        elsif (m = Tablator::CORDE_CASE_RE.match(token))
          _corde, kase, d, rh, lh = m.captures
          matrix[m[1].to_i - 1][col] = Cell.new(kase.to_i, rh, lh)
          d
        end
      next unless m

      col += span_from_duration(duree, unit_denominator)
    end
    [matrix, bars, rests]
  end

  # Inverse de `duration_for` : "4" (0 point) -> 2 colonnes (croche unit_denominator=8) ;
  # "4." -> 3 ; durée absente -> 1 colonne.
  def self.span_from_duration(duree, unit_denominator)
    return 1 unless duree

    m = /\A(\d+)(\.*)\z/.match(duree)
    return 1 unless m

    base_denom = m[1].to_i
    dots = m[2].length
    ((2**(dots + 1)) - 1) * unit_denominator / (base_denom * (2**dots))
  end

  def self.save_tablature(tokens, meta, unit, edit_path)
    meta["unit"] = unit
    _temp_path, out_base = tab_paths_for(meta, edit_path)
    out_path = edit_path || "#{out_base}.tab"

    File.write(out_path, serialize(meta, tokens))
    out_path
  end
end
