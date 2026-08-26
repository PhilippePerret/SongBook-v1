# frozen_string_literal: true

require "tty-prompt"
require_relative "chord_line"
require_relative "chord_diagrams"
require_relative "locale"
require_relative "ansi_colors"
require_relative "transpose"

# `songbook add chords <chanson>` : pose interactive des accords sur un `.lyr` EXISTANT.
# Entrée = FINIR l'édition (jamais "ligne suivante" — seules les flèches ↑/↓ déplacent
# entre les vers, ←/→ syllabe par syllabe, avec saut de vers en butée). Enregistrement
# TOUJOURS soumis à validation (Entrée comme Ctrl+C), jamais silencieux.
# Pose d'accord : taper une lettre — correspond à un raccourci déjà connu (minuscule) =>
# accord existant posé ; sinon => saisie d'un NOUVEAU nom d'accord (`typing`, affiché en
# direct sous le curseur), validée par Entrée OU simplement en bougeant (n'importe quelle
# flèche). Collision minuscule déjà prise ("a" = "Am7") : la MAJUSCULE ("A") force la
# saisie d'un nouvel accord plutôt que de reprendre l'existant.
# `-icanon -echo` (PAS `stty raw` — `raw` coupe aussi ISIG et OPOST : Ctrl+C ne
# signalait plus rien, et `\n` n'effectuait plus de retour chariot, d'où le décalage en
# escalier constaté) : lecture caractère par caractère, ISIG/OPOST intacts, Ctrl+C
# redevient un vrai SIGINT (`Interrupt`, standard Ruby). JAMAIS Échap pour quitter
# (interdiction du projet) — seul Ctrl+C sort.
# Maj+Alt et Maj+Ctrl abandonnés (Phil, diagnostic en direct : le terminal les
# intercepte lui-même pour déplacer son propre curseur, aucun octet n'atteint le
# programme — pas contournable côté code) : seul Maj+flèche (1 espace) reste.
module ChordPlacer
  ESC = "\e"
  # Pavé numérique en mode application (DECKPAM, `\e=`) : `\eOp`.."\eOy" = touches
  # 0-9 du pavé, distinctes de la ligne du haut du clavier — sans ce mode indiscernables.
  KEYPAD_DIGIT = { "p" => :kp0, "q" => :kp1, "r" => :kp2, "s" => :kp3, "t" => :kp4,
                   "u" => :kp5, "v" => :kp6, "w" => :kp7, "x" => :kp8, "y" => :kp9 }.freeze
  KEYPAD_DIGITS = (1..9).map { |n| :"kp#{n}" }.freeze

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
    "x sup | A-G Nouvel accord",
    "J/L début/fin vers | T/V début/fin chanson",
    "Enter Sauver | ^c Annuler",
  ].freeze
  HELP_COLOR = "\e[90m"
  ANSI_RESET = "\e[0m"

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
    # {letter:, pos:, cursor:} du DERNIER accord posé via une lettre encore ambiguë
    # (plusieurs accords partagent cette 1re lettre) — une touche du pavé numérique
    # juste après corrige CET accord précis, tant qu'aucune autre touche ne s'est
    # glissée entre les deux (Phil : "a" + "2" = 2e "La" rencontré).
    pending = nil
    # Nom d'accord en cours de saisie (String) au curseur courant, affiché en direct,
    # `nil` tant qu'aucune saisie n'est en cours (voir en-tête du fichier).
    typing = nil

    commit_typing = lambda do
      chord = capitalize_chord(typing)
      register_chord(letters, chord)
      save_cached_chords(song_dir, letters.values.flatten)
      chord_lines[editable[pos]].set_chord(cursor, chord)
      notice = chord_notice(chord, song_dir)
      dirty = true
      typing = nil
    end

    begin
      with_raw_terminal do
        loop do
          current = chord_lines[editable[pos]]
          render_window(editable, chord_lines, pos, cursor, letters, notice, typing)
          key = read_key
          keep_pending = false

          if typing
            case key
            when :enter
              commit_typing.call
            when :backspace
              typing = typing.length > 1 ? typing[0..-2] : nil
            when ->(k) { k.is_a?(Hash) && k[:arrow] }
              commit_typing.call
              pos, cursor = apply_arrow(key, pos, cursor, chord_lines, editable)
            when String
              typing << key if key.length == 1
            end
            next
          end

          case key
          when :enter
            break
          when "x", "X"
            if current.chord_at(cursor)
              current.delete_chord(cursor)
              dirty = true
            end
          when *KEYPAD_DIGITS
            if pending
              digit = key.to_s.delete_prefix("kp").to_i
              bucket = letters[pending[:letter]]
              chord = bucket && bucket[digit - 1]
              if chord
                chord_lines[editable[pending[:pos]]].set_chord(pending[:cursor], chord)
                dirty = true
                keep_pending = true
              end
            end
          when "J"
            cursor = 0
          when "L"
            cursor = current.text.length
          when "T"
            pos = 0
            cursor = 0
          when "V"
            pos = editable.length - 1
            cursor = 0
          when ->(k) { k.is_a?(Hash) && k[:arrow] }
            pos, cursor = apply_arrow(key, pos, cursor, chord_lines, editable)
          when ->(k) { pending && k.is_a?(String) && k.match?(/\A\d\z/) }
            # Chiffre juste après une lettre encore ambiguë (Phil, 2026-08-26, "F7" :
            # "f" seul plaçait "F" tout de suite, "7" ensuite était juste ignoré,
            # impossible d'entrer "F7"). "<Lettre>+chiffre" correspond à un AUTRE
            # accord déjà connu de cette lettre (ex. "a"+"7" = "A7" déjà enregistré) =>
            # corrige l'accord posé vers celui-là. Sinon => "<Lettre>+chiffre" n'existe
            # PAS => FORCÉMENT un nouvel accord (Phil) : annule le raccourci posé par
            # erreur, reprend la saisie comme si la lettre avait lancé `typing`.
            letter = pending[:letter]
            candidate = "#{letter.upcase}#{key}"
            if letters[letter]&.include?(candidate)
              chord_lines[editable[pending[:pos]]].set_chord(pending[:cursor], candidate)
              dirty = true
              keep_pending = true
            else
              chord_lines[editable[pending[:pos]]].delete_chord(pending[:cursor])
              typing = candidate
              dirty = true
            end
          else
            resolved = resolve_letter(key, letters)
            if resolved
              if resolved[:existing]
                current.set_chord(cursor, resolved[:existing])
                dirty = true
                pending = { letter: resolved[:letter], pos: pos, cursor: cursor }
                keep_pending = true
              else
                typing = resolved[:new]
              end
            end
          end

          pending = nil unless keep_pending
        end
      end
    rescue Interrupt
      nil
    end

    # Terminal déjà restauré ici (ensure de `with_raw_terminal`, qu'on sorte par
    # `break` ou par Ctrl+C). Rien demandé si RIEN n'a changé (Phil) — sinon TOUJOURS
    # soumis à validation, jamais un enregistrement silencieux.
    save.call if dirty && TTY::Prompt.new.yes?(Loc.get("save_changes_question"))
  end

  def self.editable_line?(line)
    !line.strip.empty? && !line.strip.match?(/\A\{[^}]*\}\z/)
  end

  # 1re lettre en capitale, TOUJOURS (Phil) — écrite comme ça, pas juste affichée comme ça.
  def self.capitalize_chord(name)
    name[0].upcase + name[1..].to_s
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
  # la même 1re lettre) : `letters[lettre]` = liste, dans l'ordre de rencontre — 1er par
  # défaut, un chiffre du pavé numérique juste après corrige vers le Nième (voir `run`).
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
      raw.scan(%r{/([^:/\s]+):}) do |m|
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
    print Loc.get("ask_song_chords")
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

  # Lettre frappée hors saisie en cours : raccourci MINUSCULE déjà connu ET frappé en
  # minuscule => accord existant repris ; sinon => nouvel accord (la MAJUSCULE force ce
  # cas même en collision avec un raccourci connu, voir en-tête du fichier). `nil` si la
  # touche n'est pas une lettre.
  def self.resolve_letter(key, letters)
    return nil unless key.is_a?(String) && key.match?(/\A[a-zA-Z]\z/)

    lower = key.downcase
    if key == lower && letters.key?(lower)
      { existing: letters[lower].first, letter: lower }
    else
      { new: key }
    end
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
  # l'ancien rôle de N/P). Alt = lettre par lettre (ajustement fin, jamais de saut de
  # vers). Shift = décalage des paroles (`shift!`), inchangé.
  def self.move_horizontal(key, pos, cursor, chord_lines, editable, direction)
    current = chord_lines[editable[pos]]
    mods = key[:mods]
    return [pos, current.shift!(cursor, 1, direction)] if mods[:shift]

    granularity = mods[:alt] ? :letter : :syllable
    new_cursor = current.move(cursor, granularity, direction)
    if new_cursor == cursor && granularity == :syllable
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
  def self.chord_known?(chord, song_dir)
    fc = ChordDiagrams.file_chord(chord)
    return true if ChordDiagrams.find_svg(song_dir, fc, nil, recursive: true)

    !!ChordDiagrams.find_svg(File.join(ChordDiagrams::ASSETS, chord[0].upcase), fc, nil, recursive: false)
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
    legend_lines(letters).each { |line| puts "#{AnsiColors::BLUE}#{line}#{AnsiColors::RESET}" }
    puts "#{HELP_COLOR}#{notice}#{ANSI_RESET}"
    puts

    window_start.upto([window_start + WINDOW_SIZE, total].min - 1) do |i|
      line = chord_lines[editable[i]]
      render_line(line, i == pos ? cursor : nil, live: i == pos ? typing : nil)
      puts
    end

    HELP_LINES.each { |l| puts "#{HELP_COLOR}#{l}#{ANSI_RESET}" }
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
