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
  # Bleu (`AnsiColors::BLUE`) pour toute question posée à l'user (Phil).
  def self.blue(text)
    "#{AnsiColors::BLUE}#{text}#{AnsiColors::RESET}"
  end

  # `create:`/`build:` (`--create`/`--build`) zappent le select initial. `tab_name:`
  # (`--tab NOM`) va direct en édition d'une tablature existante (cherchée dans la
  # chanson de contexte, `Session.song`).
  def self.run(create: false, build: false, tab_name: nil)
    return write_tablature(edit_path: resolve_tab_path(tab_name)) if tab_name

    choice =
      if create then :write
      elsif build then :svg
      else
        TTY::Prompt.new.select(blue(Loc.get("tablator_assistant_question")), [
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
    meta, = Tablator.parse_frontmatter(content)
    ly = Tablator.to_lilypond(content, notes_mode: false, base_dir: File.dirname(tab_path))
    out_base ||= tab_path.sub(/\.tab\z/, "")
    File.write("#{out_base}.ly", ly) if meta["keep_ly"]
    Tablator.render_svg(ly, out_base)
    puts "#{AnsiColors::SUCCESS}👍 #{Loc.get('tablator_svg_produced')}#{AnsiColors::RESET}"
  rescue Tablator::ParseError => e
    warn "#{tab_path} : #{e.message}"
  end

  def self.resolve_tab_path(name)
    song_folder = Session.song
    abort "aucune chanson de contexte pour --tab (--song ou use song)" unless song_folder

    candidates = Dir.glob(File.join(song_folder, "**", "*.tab"))
    found = candidates.find { |p| File.basename(p, ".tab") == name }
    found ||= candidates.find { |p| CarnetBuilder.slugify(File.basename(p, ".tab")) == CarnetBuilder.slugify(name) }
    abort "tablature introuvable : #{name}" unless found

    found
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

  # Rangée des chiffres d'un clavier AZERTY SANS Shift (Phil) -> chiffre équivalent.
  AZERTY_DIGITS = {
    "&" => "1", "é" => "2", "\"" => "3", "'" => "4", "(" => "5",
    "-" => "6", "è" => "7", "_" => "8", "ç" => "9", "à" => "0",
  }.freeze

  KEY_SEQUENCES = {
    "\e[A" => :up, "\e[B" => :down, "\e[C" => :right, "\e[D" => :left,
    "\e[1;2C" => :shift_right, "\e[1;2D" => :shift_left,
  }.freeze

  # Éditeur console : curseur déplacé ←/→ et ↑/↓, chiffres 0-9 (case, 2 chiffres max,
  # clavier AZERTY sans Shift accepté), `x` efface, Shift+←/→ repousse tout ce qui
  # suit le curseur (Shift+← écrase la colonne du curseur, le reste se décale dedans),
  # `c` ouvre la config, `s` produit le SVG SANS quitter (état courant écrit dans un
  # fichier `.tab` PROVISOIRE CACHÉ `.~<nom>.tab`, le SVG produit porte lui le nom
  # normal), `q` termine et enregistre, Ctrl+C annule. Le fichier provisoire est
  # TOUJOURS détruit en sortie (`ensure`, y compris sur Ctrl+C, Phil). `edit_path:` :
  # tablature existante chargée dans la grille (frontmatter -> `title`/`unit`/
  # `metrique`, corps -> matrice), réenregistrée au même endroit (sinon nouveau
  # fichier, titre demandé).
  def self.write_tablature(edit_path: nil)
    meta = {}
    tokens_in = []
    if edit_path
      meta, body = Tablator.parse_frontmatter(File.read(edit_path))
      tokens_in = Tablator.tokenize(body)
    end
    unit = meta["unit"] || DEFAULT_UNIT
    metrique = meta["metrique"]
    temp_path = nil

    console_width = ($stdin.winsize[1] - ROW_MARGIN) / COL_WIDTH
    width = [console_width, columns_needed(tokens_in, unit)].max
    matrix = matrix_from_tokens(tokens_in, width, unit)
    string = 1
    col = 0
    editing_at = nil

    begin
      begin
        $stdin.raw(intr: true) do
          loop do
            draw_grid(matrix, string, col, unit)
            key = read_key
            key = AZERTY_DIGITS.fetch(key, key) if key.is_a?(String)
            case key
            when :up then string = [string - 1, 1].max
            when :down then string = [string + 1, 6].min
            when :left then col = [col - 1, 0].max
            when :right then col = [col + 1, width - 1].min
            when :shift_right
              shift_right!(matrix, col)
            when :shift_left
              shift_left!(matrix, col)
            when "x"
              matrix[string - 1][col] = nil
              editing_at = nil
              next
            when "c"
              unit, metrique = open_config(unit, metrique)
            when "s"
              temp_path, out_base = tab_paths_for(meta, edit_path)
              meta["unit"] = unit
              meta["metrique"] = metrique if metrique
              File.write(temp_path, serialize(meta, matrix_to_tokens(matrix, unit)))
              render_tab_svg(temp_path, out_base: out_base)
            when "q"
              break
            when /\A\d\z/
              if editing_at == [string, col] && matrix[string - 1][col]
                candidate = "#{matrix[string - 1][col]}#{key}".to_i
                matrix[string - 1][col] = candidate <= MAX_CASE ? candidate : key.to_i
              else
                matrix[string - 1][col] = key.to_i
              end
              editing_at = [string, col]
              next
            end
            editing_at = nil
          end
        end
      rescue Interrupt
        puts
        puts Loc.get("build_cancelled")
        return
      end

      tokens = matrix_to_tokens(matrix, unit)
      if tokens.empty?
        puts Loc.get("tablator_write_empty")
        return
      end

      meta["metrique"] = metrique if metrique
      out_path = save_tablature(tokens, meta, unit, edit_path)
      puts Loc.get("tablator_write_saved")

      return unless TTY::Prompt.new.yes?(blue(Loc.get("tablator_build_now_question")))

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
      meta["title"] ||= TTY::Prompt.new.ask(blue("Titre :")) { |q| q.required true }
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
  def self.shift_right!(matrix, col)
    matrix.each do |row|
      row.insert(col, nil)
      row.pop
    end
  end

  def self.shift_left!(matrix, col)
    matrix.each do |row|
      row.delete_at(col)
      row.push(nil)
    end
  end

  def self.open_config(unit, metrique)
    choice = TTY::Prompt.new.select(blue(Loc.get("tablator_config_menu")), [
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
    TTY::Prompt.new.select(blue(Loc.get("tablator_config_question")), choices, default: choices.index(current).to_i + 1, show_help: false)
  end

  def self.ask_metrique
    prompt = TTY::Prompt.new
    haut = prompt.ask(blue(Loc.get("tablator_metrique_top"))) { |q| q.validate(/\A\d+\z/) }
    bas = prompt.ask(blue(Loc.get("tablator_metrique_bottom"))) { |q| q.validate(/\A\d+\z/) }
    "#{haut}/#{bas}"
  end

  def self.draw_grid(matrix, cur_string, cur_col, unit)
    print "\e[2J\e[H"
    (1..6).each do |string|
      row = matrix[string - 1].each_with_index.map do |kase, col|
        cell = kase.nil? ? "-" * COL_WIDTH : kase.to_s.ljust(COL_WIDTH, "-")
        string == cur_string && col == cur_col ? "\e[7m#{cell}\e[0m" : cell
      end.join
      puts "#{STRING_LABELS[string - 1]}|#{row}|"
    end
    puts "#{AnsiColors::GRAY}#{format(Loc.get('tablator_write_help'), unit)}#{AnsiColors::RESET}"
  end

  # Séquence CSI (`ESC [ ... lettre-finale`) lue en entier (longueur variable, ex.
  # `ESC [ 1 ; 2 C` pour Shift+→) — lire un nombre fixe d'octets après ESC cassait sur
  # ces séquences plus longues que les flèches simples.
  def self.read_key
    c = $stdin.getc
    return c unless c == "\e"

    seq = c + $stdin.getc
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
  # l'événement suivant (ou la fin), converti en durée LilyPond pointée via
  # `duration_for`. Plusieurs cordes sur la même colonne -> accord `<corde:case ...>`.
  # Un trou AVANT la première note (Phil) compte aussi (placement des barres) mais
  # n'est PAS marqué par défaut (levée) -> silence INVISIBLE (`sN`, "skip" LilyPond),
  # jamais supprimé silencieusement.
  def self.matrix_to_tokens(matrix, unit)
    width = matrix.first.length
    unit_denominator = DURATIONS.fetch(unit)
    events = (0...width).filter_map do |col|
      notes = (1..6).filter_map { |string| matrix[string - 1][col] && "#{string}#{matrix[string - 1][col]}" }
      [col, notes] unless notes.empty?
    end
    return [] if events.empty?

    notes_tokens = events.each_with_index.map do |(col, notes), i|
      next_col = i + 1 < events.length ? events[i + 1][0] : width
      duree = duration_for(next_col - col, unit_denominator)
      (notes.size == 1 ? notes.first : "<#{notes.join(' ')}>") + "/#{duree}"
    end

    leading = events.first[0]
    leading.positive? ? ["s#{duration_for(leading, unit_denominator)}"] + notes_tokens : notes_tokens
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
  # visuellement le "trou". Barres `|` non représentées dans la grille (limite connue).
  # Nombre de colonnes qu'occuperont `tokens` une fois rechargés (span par span, voir
  # `span_from_duration`) — utilisé pour dimensionner la grille au chargement d'une
  # tablature existante (`--tab`) si elle dépasse la largeur de la console.
  def self.columns_needed(tokens, unit)
    unit_denominator = DURATIONS.fetch(unit)
    col = 0
    tokens.each do |token|
      next if token == "|"

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

  def self.matrix_from_tokens(tokens, width, unit)
    matrix = Array.new(6) { Array.new(width) }
    unit_denominator = DURATIONS.fetch(unit)
    col = 0
    tokens.each do |token|
      next if token == "|"
      break if col >= width

      if (rm = Tablator::REST_RE.match(token))
        col += span_from_duration(rm[2], unit_denominator)
        next
      end

      duree =
        if (m = Tablator::CHORD_RE.match(token))
          m[2].split(/\s+/).each do |pair|
            cm = Tablator::CORDE_CASE_RE.match(pair)
            matrix[cm[1].to_i - 1][col] = cm[2].to_i if cm
          end
          m[3]
        elsif (m = Tablator::CORDE_CASE_RE.match(token))
          matrix[m[1].to_i - 1][col] = m[2].to_i
          m[3]
        end
      next unless m

      col += span_from_duration(duree, unit_denominator)
    end
    matrix
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
