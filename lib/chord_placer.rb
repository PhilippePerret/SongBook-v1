# frozen_string_literal: true

require "tty-prompt"
require_relative "chord_line"
require_relative "chord_diagrams"
require_relative "locale"
require_relative "ansi_colors"
require_relative "transpose"
require_relative "dsl_parser"

# `songbook add chords <chanson>` : pose interactive des accords sur un `.lyr` EXISTANT.
# Entrée = FINIR l'édition (jamais "ligne suivante" — seules les flèches ↑/↓ déplacent
# entre les vers, ←/→ syllabe par syllabe, avec saut de vers en butée). Enregistrement
# TOUJOURS soumis à validation (Entrée comme Ctrl+C), jamais silencieux.
# Pose d'accord : TOUTE lettre démarre `typing` (buffer des caractères tapés tels
# quels), qu'elle corresponde ou non à un raccourci — la décision "accord existant ou
# nouveau" (`typed_match`) se refait à CHAQUE frappe, pas une fois pour toutes (Phil,
# 2026-08-26 : "un chiffre est un chiffre" — plus de distinction clavier/pavé numérique,
# plus de correction par INDEX du pavé numérique, un chiffre ÉTEND juste le nom en
# cours). Règle : si `typing` (minuscule initiale) correspond EXACTEMENT à un accord
# déjà connu de cette lettre => affiché/validé comme CET accord existant ; sinon =>
# affiché/validé comme nouvel accord (texte tapé tel quel, capitalisé). MAJUSCULE
# initiale : jamais un raccourci, toujours un nouvel accord, quoi qu'il arrive ensuite.
# Une touche-commande (flèche, x/X/J/L/T/V/n/p, Entrée) interrompt/valide la saisie en
# cours avec l'état COURANT (accord existant si ça matchait à cet instant, sinon nouveau
# accord tel que tapé) — Entrée EN PLUS termine la saisie SANS quitter l'éditeur (il en
# faut une 2e pour ça), les autres touches-commandes valident ET s'exécutent dans la
# foulée (Phil : "flèche valide aussi l'accord en cours, sans Entrée" — généralisé).
# `-icanon -echo` (PAS `stty raw` — `raw` coupe aussi ISIG et OPOST : Ctrl+C ne
# signalait plus rien, et `\n` n'effectuait plus de retour chariot, d'où le décalage en
# escalier constaté) : lecture caractère par caractère, ISIG/OPOST intacts, Ctrl+C
# redevient un vrai SIGINT (`Interrupt`, standard Ruby). JAMAIS Échap pour quitter
# (interdiction du projet) — seul Ctrl+C sort.
# Maj+Alt, Maj+Ctrl, Alt+flèche ET Ctrl+flèche abandonnés (Phil, diagnostic en direct :
# le terminal les intercepte lui-même pour déplacer son propre curseur, aucun octet
# n'atteint le programme — pas contournable côté code, testé et confirmé 2026-08-26)
# : seul Maj+flèche (1 espace) reste côté flèches modifiées. Lettre par lettre : "n"/
# "p" (touches dédiées, jamais interceptées par le terminal), pas de modificateur.
module ChordPlacer
  extend AnsiColors

  ESC = "\e"
  # Pavé numérique en mode application (DECKPAM, `\e=`) : `\eOp`.."\eOy" = touches
  # 0-9 du pavé, distinctes de la ligne du haut du clavier — sans ce mode indiscernables.
  KEYPAD_DIGIT = { "p" => :kp0, "q" => :kp1, "r" => :kp2, "s" => :kp3, "t" => :kp4,
                   "u" => :kp5, "v" => :kp6, "w" => :kp7, "x" => :kp8, "y" => :kp9 }.freeze
  KEYPAD_DIGITS = (1..9).map { |n| :"kp#{n}" }.freeze

  # Rangée du haut d'un clavier AZERTY français SANS Maj = ces symboles, pas les
  # chiffres (Phil, 2026-08-26, confirmé jusqu'au 0 = "à") — un chiffre tapé
  # "normalement" (sans forcer Maj) arrive comme ça en frappe brute. Même table que
  # `TablatorAssistant::AZERTY_DIGITS`.
  AZERTY_DIGITS = { "&" => "1", "é" => "2", "\"" => "3", "'" => "4", "(" => "5",
                     "§" => "6", "è" => "7", "!" => "8", "ç" => "9", "à" => "0" }.freeze

  MODIFIERS = {
    nil => {},
    "2" => { shift: true },
    "3" => { alt: true },
    "4" => { shift: true, alt: true },
    "5" => { ctrl: true },
    "6" => { shift: true, ctrl: true },
    "7" => { alt: true, ctrl: true },
    "8" => { shift: true, alt: true, ctrl: true },
    "9" => { alt: true }, # variante rencontrée sur certains terminaux (Option seul)
  }.freeze

  ARROW = { "A" => :up, "B" => :down, "C" => :right, "D" => :left }.freeze
  WINDOW_SIZE = 4
  # ≤45 signes par ligne (Phil).
  HELP_LINES = [
    "x sup acc | X sup tous | A-G Nouvel accord",
    "J/L début/fin vers | T/V début/fin chanson",
    "←/→ ←Syllabe→ | n/p ←Lettre→ |",
    "Enter Sauver | ^c Annuler",
  ].freeze

  def self.run(lyr_path)
    song_dir = File.dirname(lyr_path)
    raw_lines = File.readlines(lyr_path, chomp: true)
    editable = raw_lines.each_index.select { |i| editable_line?(raw_lines[i]) }
    return if editable.empty?

    chord_lines = editable.to_h { |i| [i, ChordLine.parse(raw_lines[i])] }
    letters = seed_letters(raw_lines)
    load_cached_chords(song_dir).each { |chord| register_chord(letters, chord) }
    ask_initial_chords(letters, song_dir) if letters.empty?

    save = lambda do
      editable.each { |i| raw_lines[i] = chord_lines[i].serialize }
      File.write(lyr_path, "#{raw_lines.join("\n")}\n")
    end

    pos = 0
    cursor = 0
    notice = nil
    dirty = false
    # Caractères tapés tels quels (String), `nil` tant qu'aucune saisie n'est en cours
    # (voir en-tête du fichier — décision existant/nouveau refaite à chaque frappe).
    typing = nil

    commit_typing = lambda do
      chord = typed_match(typing, letters) || capitalize_chord(typing)
      register_chord(letters, chord)
      save_cached_chords(song_dir, letters.values.flatten)
      chord_lines[editable[pos]].set_chord(cursor, chord)
      notice = chord_notice(chord, song_dir)
      dirty = true
      typing = nil
    end

    # Touches-commande qui interrompent une saisie en cours ET s'exécutent ensuite
    # normalement (voir en-tête du fichier) — Entrée/Retour arrière traités À PART
    # (Entrée valide SANS s'exécuter comme "quitter", Retour arrière édite le buffer).
    command_key = lambda do |k|
      (k.is_a?(Hash) && k[:arrow]) || (k.is_a?(String) && %w[x X J L T V n p].include?(k))
    end

    begin
      with_raw_terminal do
        loop do
          current = chord_lines[editable[pos]]
          live = typing && (typed_match(typing, letters) || typing)
          render_window(editable, chord_lines, pos, cursor, active_letters(letters, chord_lines), notice, live)
          key = read_key

          if typing
            digit = normalize_digit(key)
            if key == :enter
              commit_typing.call
              next
            elsif key == :backspace
              typing = typing.length > 1 ? typing[0..-2] : nil
              next
            elsif command_key.call(key)
              commit_typing.call
              # PAS de `next` : tombe dans le dispatch normal ci-dessous, MÊME touche
              # (`typing` vient d'être remis à `nil`).
            elsif digit
              typing << digit
              next
            elsif key.is_a?(String) && key.length == 1
              typing << key
              next
            else
              next
            end
          end

          case key
          when :enter
            break
          when "x"
            if current.chord_at(cursor)
              current.delete_chord(cursor)
              dirty = true
            end
          when "X"
            if editable.any? { |i| chord_lines[i].chords.any? } && confirm_delete_all
              editable.each { |i| chord_lines[i].chords.clear }
              dirty = true
            end
          when "J"
            cursor = 0
          when "L"
            cursor = current.text.length
          when "n"
            cursor = current.move(cursor, :letter, 1)
          when "p"
            cursor = current.move(cursor, :letter, -1)
          when "T"
            pos = 0
            cursor = 0
          when "V"
            pos = editable.length - 1
            cursor = 0
          when ->(k) { k.is_a?(Hash) && k[:arrow] }
            pos, cursor = apply_arrow(key, pos, cursor, chord_lines, editable)
          else
            # "[" (Phil, 2026-08-28) démarre aussi une saisie : basse SEULE, ex. "[fd]"
            # ("basse fa dièse", toujours enregistrée en minuscule, `capitalize_chord`)
            # — même syntaxe crochets que la basse embarquée dans un accord (`A[c]m7`,
            # Manuel/song/chords.adoc), affichée en rendu "/fa♯" (solfège italien,
            # `Layout.display_chord`/`Layout.italian_bass_symbol`).
            typing = key if key.is_a?(String) && key.match?(/\A[a-zA-Z\[]\z/)
          end
        end
      end
    rescue Interrupt
      nil
    end

    # Terminal déjà restauré ici (ensure de `with_raw_terminal`, qu'on sorte par
    # `break` ou par Ctrl+C). Rien demandé si RIEN n'a changé (Phil) — sinon TOUJOURS
    # soumis à validation, jamais un enregistrement silencieux.
    save.call if dirty && colored_prompt.yes?(blue(Loc.get("save_changes_question")), default: false)
  end

  def self.editable_line?(line)
    !line.strip.empty? && !line.strip.match?(/\A\{[^}]*\}\z/)
  end

  # 1re lettre en capitale, TOUJOURS (Phil) — écrite comme ça, pas juste affichée comme
  # ça. Basse entre crochets (`[fd]` seule, ou embarquée dans un accord "A[c]m7", Phil
  # 2026-08-28 : "entre crochets, c'est toujours des basses et les basses doivent
  # toujours s'écrire en minuscule") : règle INVERSE, tout le contenu d'un "[...]" est
  # forcé en minuscule — même règle que `DSLParser.normalize_chord`, pas de
  # ré-implémentation, une seule règle partout.
  def self.capitalize_chord(name)
    DSLParser.normalize_chord(name)
  end

  # Étiquette d'un accord dans la légende : raccourci clavier (lettre + éventuel chiffre,
  # voir `register_chord`) = vrai nom d'accord entré, jamais tronqué/réencodé.
  def self.chord_label(letter, index, chord)
    index.zero? ? "#{letter} = #{chord}" : "#{letter}#{index + 1} = #{chord}"
  end

  # Nom RÉEL d'un accord (lettre + altération, ex. "D#", "Bb" — `Transpose::CHORD_RE`,
  # même regex que la transposition, pas de ré-implémentation maison qui risquerait de
  # mal encoder l'altération, ex. "Dd" au lieu de "D#").
  def self.chord_nom(chord)
    Transpose::CHORD_RE.match(chord)&.captures&.first || chord
  end

  # Légende affichée = seulement les accords RÉELLEMENT posés quelque part dans la
  # chanson EN CE MOMENT (Phil, 2026-08-26 : bug constaté, la légende gardait tous les
  # accords jamais tapés/mis en cache, même retirés depuis). `letters` complet (avec
  # les accords mis en cache mais plus posés) reste utilisé PARTOUT ailleurs (raccourcis
  # encore disponibles au clavier, `.cached` — voir `save_cached_chords`) : seul
  # l'AFFICHAGE de la légende est filtré ici.
  def self.active_letters(letters, chord_lines)
    used = chord_lines.values.flat_map { |cl| cl.chords.values }.uniq
    letters.each_with_object({}) do |(letter, chords), h|
      kept = chords.select { |c| used.include?(c) }
      h[letter] = kept unless kept.empty?
    end
  end

  # 1 ligne (tous les raccourcis) tant que c'est lisible, sinon 1 ligne PAR NOM RÉEL
  # d'accord (Phil : "A" différent de "A#", même s'ils partagent le raccourci "a") dès
  # que > 4 noms différents OU > 8 accords différents au total.
  def self.legend_lines(letters)
    entries = letters.flat_map { |l, chords| chords.each_with_index.map { |c, i| [l, i, c] } }
    noms = entries.group_by { |(_l, _i, c)| chord_nom(c) }

    if noms.size > 4 || entries.size > 8
      noms.map { |_nom, group| group.map { |l, i, c| chord_label(l, i, c) }.join("  ") }
    else
      [entries.map { |l, i, c| chord_label(l, i, c) }.join("  ")]
    end
  end

  # Raccourci = 1re lettre du NOM de l'accord (Phil : "a" = "A7M", "b" = "Bm9b" — plus
  # confusionnant qu'un ordre a/b/c/d arbitraire). Collision (plusieurs accords partagent
  # la même 1re lettre) : `letters[lettre]` = liste, dans l'ordre de rencontre —
  # désambiguïsée en continuant à taper le nom complet (voir `typed_match`).
  def self.register_chord(letters, chord)
    letter = chord[0].downcase
    letters[letter] ||= []
    letters[letter] << chord unless letters[letter].include?(chord)
    letter
  end

  # {lettre => [accords]}, amorcée à partir de TOUS les accords déjà présents dans le
  # fichier (ordre d'apparition).
  def self.seed_letters(lines)
    letters = {}
    seen = []
    lines.each do |raw|
      # `DSLParser::CHORD_RE` (pas une regex maison) : un accord "slash" (ex. "Bb6/C")
      # a bien un "/" INTERNE à son nom — une regex qui l'exclut le coupe en 2 et ne
      # récupère que la partie après le dernier "/" (bug constaté, Phil : "il s'agit de
      # deux accords" alors que "Bb6/C" est UN accord unique avec basse).
      raw.scan(DSLParser::CHORD_RE) do |m|
        chord = capitalize_chord(m[0])
        next if seen.include?(chord)

        seen << chord
        register_chord(letters, chord)
      end
    end
    letters
  end

  # Demandée AVANT toute édition (hors mode brut : lecture de ligne normale). Skip si
  # rien à ajouter (Entrée seule).
  def self.ask_initial_chords(letters, song_dir)
    print blue(Loc.get("ask_song_chords"))
    STDOUT.flush
    input = $stdin.gets.to_s.strip
    added = false
    input.split(/[\s,]+/).each do |raw_chord|
      next if raw_chord.empty?

      chord = capitalize_chord(raw_chord)
      next if letters.values.flatten.include?(chord)

      register_chord(letters, chord)
      added = true
      notice = chord_notice(chord, song_dir)
      puts notice if notice
    end
    save_cached_chords(song_dir, letters.values.flatten) if added
  end

  # `.cached` (dossier de la chanson) : `chord_list:` — conserve les accords donnés/
  # ajoutés au fil de l'édition MÊME NON UTILISÉS (Phil : sinon ils disparaissent
  # simplement, jamais posés nulle part dans le `.lyr` donc jamais retrouvés). Réservé
  # à d'autres infos à l'avenir (root-name fixe ".cached", pas de forme libre).
  def self.cached_path(song_dir)
    File.join(song_dir, ".cached")
  end

  def self.load_cached_chords(song_dir)
    path = cached_path(song_dir)
    return [] unless File.exist?(path)

    line = File.readlines(path).find { |l| l.start_with?("chord_list:") }
    return [] unless line

    line.split(":", 2).last.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  def self.save_cached_chords(song_dir, chords)
    path = cached_path(song_dir)
    lines = File.exist?(path) ? File.readlines(path) : []
    new_line = "chord_list: #{chords.join(", ")}\n"
    idx = lines.index { |l| l.start_with?("chord_list:") }
    idx ? (lines[idx] = new_line) : (lines << new_line)
    File.write(path, lines.join)
  end

  # `typing` (buffer tel que tapé) correspond-il à un accord déjà connu ? Nom RÉEL de
  # cet accord si oui, `nil` sinon — MAJUSCULE initiale : jamais de correspondance,
  # toujours `nil` (voir en-tête du fichier, règle Phil 2026-08-26).
  def self.typed_match(typing, letters)
    return nil if typing[0].match?(/[A-Z]/)

    bucket = letters[typing[0].downcase]
    return nil unless bucket

    # 1 seule lettre tapée = raccourci immédiat (Phil, 2026-08-26 : "b" -> "Bdim" même
    # si "B" seul n'existe pas — bug constaté, le nom tapé devait matcher EXACTEMENT,
    # cassait le raccourci 1 lettre pour tout accord de plus d'1 caractère). Au-delà
    # d'1 caractère, correspondance EXACTE seulement (nécessaire pour "f"+"7" : "F7"
    # existant repris seulement si "F7" lui-même est déjà connu, pas juste "F...").
    return bucket.first if typing.length == 1

    # "b2" = 2e accord de la lettre "b" (voir `chord_label`, légende "b2 = ...") : raccourci
    # par INDEX, PRIORITAIRE sur la correspondance exacte (Phil, 2026-08-27 : un accord
    # inutilisé mais encore en cache — ex. "B2" — ne doit JAMAIS voler le raccourci de
    # position, sinon "b2" devient injoignable tant que ce résidu traîne). Correspondance
    # exacte seulement en repli, si l'index tapé ne pointe aucune position du bucket
    # (nécessaire pour "f"+"7" : "F7" existant repris seulement si "F7" lui-même est déjà
    # connu, pas juste "F...").
    m = typing.match(/\A[a-z](\d+)\z/)
    if m
      idx = m[1].to_i - 1
      return bucket[idx] if idx >= 0 && idx < bucket.size
    end

    candidate = capitalize_chord(typing)
    bucket.include?(candidate) ? candidate : nil
  end

  # Un chiffre est un chiffre (Phil, 2026-08-26) : haut du clavier, pavé numérique
  # (`\eOp`..`\eOy`, mode application DECKPAM) ou rangée du haut d'un AZERTY sans Maj
  # (`AZERTY_DIGITS`) — les trois formes normalisées vers le même caractère "0".."9".
  # `nil` si `key` n'est pas un chiffre, sous quelque forme que ce soit.
  def self.normalize_digit(key)
    return key.to_s.delete_prefix("kp") if key.is_a?(Symbol) && (key == :kp0 || KEYPAD_DIGITS.include?(key))
    return AZERTY_DIGITS[key] if key.is_a?(String) && AZERTY_DIGITS.key?(key)
    return key if key.is_a?(String) && key.match?(/\A\d\z/)

    nil
  end

  def self.apply_arrow(key, pos, cursor, chord_lines, editable)
    case key[:arrow]
    when :up then move_vertical(pos, cursor, chord_lines, editable, -1)
    when :down then move_vertical(pos, cursor, chord_lines, editable, 1)
    when :right then move_horizontal(key, pos, cursor, chord_lines, editable, 1)
    when :left then move_horizontal(key, pos, cursor, chord_lines, editable, -1)
    end
  end

  # Pages FIXES (`WINDOW_SIZE`) : ↑/↓ dans la page ne touche qu'au curseur (repositionné
  # dans la limite du texte de la nouvelle ligne), seul le passage à la page suivante
  # ramène le curseur en tête (Phil).
  def self.move_vertical(pos, cursor, chord_lines, editable, direction)
    return [pos, cursor] if (direction.negative? && pos.zero?) || (direction.positive? && pos == editable.length - 1)

    page_before = pos / WINDOW_SIZE
    pos += direction
    same_page = pos / WINDOW_SIZE == page_before
    cursor = same_page ? [cursor, chord_lines[editable[pos]].text.length].min : 0
    [pos, cursor]
  end

  # ←/→ nu = syllabe par syllabe, avec saut au vers suivant/précédent en butée (reprend
  # l'ancien rôle de N/P). Shift = décalage des paroles (`shift!`), inchangé. Lettre par
  # lettre : voir "n"/"p" (`run`) — PAS ici, Alt/Ctrl+flèche abandonnés (en-tête du
  # fichier, interceptés par le terminal avant d'atteindre le programme).
  def self.move_horizontal(key, pos, cursor, chord_lines, editable, direction)
    current = chord_lines[editable[pos]]
    mods = key[:mods]
    return [pos, current.shift!(cursor, 1, direction)] if mods[:shift]

    new_cursor = current.move(cursor, :syllable, direction)
    if new_cursor == cursor
      if direction.positive? && pos < editable.length - 1
        pos += 1
        cursor = 0
      elsif direction.negative? && pos.positive?
        pos -= 1
        cursor = chord_lines[editable[pos]].text.length
      end
    else
      cursor = new_cursor
    end
    [pos, cursor]
  end

  # Vérifie l'existence d'un diagramme pour cet accord (dossier de la chanson, puis
  # `assets/chords_diags/` de l'app — les 2 sources demandées) — signalé, discret,
  # jamais négatif : `nil` si trouvé (rien à signaler), sinon un message neutre.
  # "-<case>" (ex. "F7M-1") : même convention que `DSLParser::CHORD_RE`/`.lyr` — accord
  # SIMPLE (pas de "-") => n'importe quelle case (`find_svg` fret nil, la plus basse) ;
  # accord PRÉCIS (avec "-<case>") => CETTE case exacte et AUCUNE AUTRE (Phil, 2026-08-26
  # : bug constaté — cherchait "F7M-1-*.svg" en traitant tout le texte comme un nom
  # opaque, jamais "F7M-1.svg" lui-même, faux "sans diagramme" alors qu'il existait).
  def self.chord_known?(chord, song_dir)
    # Basse seule (`[fd]`, Phil 2026-08-28) : aucun diagramme dédié n'existe pour ce
    # cas (convention absente de `GenerateChordDiagrams`), le signaler serait donc
    # TOUJOURS un faux négatif — rien à signaler.
    return true if chord.start_with?("[")

    name, fret = chord.split("-", 2)
    fc = ChordDiagrams.file_chord(name)
    return true if ChordDiagrams.find_svg(song_dir, fc, fret, recursive: true)

    !!ChordDiagrams.find_svg(File.join(ChordDiagrams::ASSETS, name[0].upcase), fc, fret, recursive: false)
  end

  def self.chord_notice(chord, song_dir)
    chord_known?(chord, song_dir) ? nil : format(Loc.get("chord_no_diagram"), chord)
  end

  # Pages FIXES de WINDOW_SIZE vers (0-3, 4-7, ...) — jamais de glissement ligne par
  # ligne : ↓ dans la page ne touche qu'au curseur, seul le passage à la page suivante
  # change ce qui est affiché (Phil).
  def self.render_window(editable, chord_lines, pos, cursor, letters, notice, typing = nil)
    total = editable.length
    window_start = (pos / WINDOW_SIZE) * WINDOW_SIZE

    print "\e[2J\e[H"
    # Note/séparateur : 2 lignes RÉSERVÉES, toujours (présentes ou vides — Phil : les
    # sauts d'écran sont intempestifs). La légende, elle, PEUT changer de nombre de
    # lignes (1 -> plusieurs) en cours d'édition — conséquence assumée du passage en
    # multi-lignes au-delà du seuil (Phil), pas un saut accidentel.
    legend_lines(letters).each { |line| puts blue(line) }
    puts gray(notice)
    puts

    window_start.upto([window_start + WINDOW_SIZE, total].min - 1) do |i|
      line = chord_lines[editable[i]]
      render_line(line, i == pos ? cursor : nil, live: i == pos ? typing : nil)
      puts
    end

    HELP_LINES.each { |l| puts gray(l) }
  end

  # Curseur AU-DESSUS des paroles (ligne des accords), jamais sur le texte lui-même —
  # c'est là qu'un accord se pose, sur une syllabe repérée depuis la ligne du dessus.
  # `live` : nom d'accord en cours de saisie au curseur, affiché SANS toucher aux
  # accords réels de la ligne tant que la saisie n'est pas validée.
  def self.render_line(chord_line, cursor, live: nil)
    chords = live && cursor ? chord_line.chords.merge(cursor => live) : chord_line.chords
    width = [chord_line.text.length, cursor.to_i + 1].max
    chords.each { |offset, name| width = [width, offset + name.length].max }
    row = Array.new(width, " ")
    chords.each do |offset, name|
      name.each_char.with_index { |c, k| row[offset + k] = c }
    end
    row[cursor] = "\e[7m#{row[cursor]}\e[0m" if cursor

    puts row.join
    puts chord_line.text
  end

  # "X" (suppression de TOUS les accords de la chanson) : action destructive, jamais
  # sans confirmation. Bascule en mode ligne le temps de la question (même raison que
  # `read_chord_name` : `TTY::Prompt` a besoin d'icanon/echo, pas du mode brut).
  def self.confirm_delete_all
    print "\e>"
    system("stty icanon echo")
    result = colored_prompt.yes?(blue(Loc.get("confirm_delete_all_chords")))
    system("stty -icanon -echo min 1 time 0")
    print "\e="
    result
  end

  def self.with_raw_terminal
    system("stty -icanon -echo min 1 time 0")
    print "\e=" # DECKPAM : distingue le pavé numérique du haut de clavier
    yield
  ensure
    print "\e>"
    system("stty icanon echo")
  end

  # rxvt/anciens terminaux : Shift+flèche en MINUSCULE, SANS paramètre (`\e[a`), pas la
  # forme `\e[1;2A` — accord+d'autres terminaux : les deux formes reconnues.
  LOWERCASE_ARROW = { "a" => :up, "b" => :down, "c" => :right, "d" => :left }.freeze

  def self.read_key
    c1 = $stdin.getc
    return decode_plain(c1) unless c1 == ESC

    c2 = $stdin.getc
    return decode_plain(c1) if c2.nil?

    # macOS Terminal.app (Option comme Meta) : double échap devant la séquence normale —
    # `\e` + `\e[C` pour Alt+Droite, par exemple.
    if c2 == ESC
      c3 = $stdin.getc
      return c2 if c3.nil?
      return with_alt(read_csi) if c3 == "["

      return "\e\e#{c3}"
    end

    if c2 == "["
      read_csi
    elsif c2 == "O"
      c3 = $stdin.getc
      KEYPAD_DIGIT[c3] || "\eO#{c3}"
    else
      "\e#{c2}"
    end
  end

  # Lecture DÉTERMINISTE (pas de "boucle jusqu'à ce que ça matche" — ambigu, pouvait
  # sur-lire des octets appartenant à la touche suivante) : après `\e[`, le caractère
  # suivant dit immédiatement de quelle forme il s'agit.
  def self.read_csi
    c = $stdin.getc
    return { arrow: ARROW[c], mods: {} } if ARROW.key?(c)
    return { arrow: LOWERCASE_ARROW[c], mods: { shift: true } } if LOWERCASE_ARROW.key?(c)
    return "\e[#{c}" unless c == "1"

    rest = +"1"
    rest << $stdin.getc while rest.length < 5 && rest !~ /[ABCD]\z/
    m = rest.match(/\A1;(\d)([ABCD])\z/)
    m ? { arrow: ARROW[m[2]], mods: MODIFIERS.fetch(m[1], {}) } : "\e[#{rest}"
  end

  def self.with_alt(key)
    return key unless key.is_a?(Hash) && key[:arrow]

    key.merge(mods: key[:mods].merge(alt: true))
  end

  # ISIG reste actif (`with_raw_terminal`) : Ctrl+C envoie un vrai SIGINT, Ruby lève
  # `Interrupt` nativement AVANT même d'atteindre ce code dans le cas normal — `\x03`
  # géré ici en secours (terminaux qui ne l'enverraient pas comme signal).
  def self.decode_plain(ch)
    case ch
    when "\x03" then raise Interrupt
    when "\r", "\n" then :enter
    when "\x7F", "\b" then :backspace
    else ch
    end
  end
end
