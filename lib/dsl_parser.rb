require "yaml"

Song    = Struct.new(:meta, :blocks, keyword_init: true)
Block   = Struct.new(:lines, :directives, :paired_with_previous, keyword_init: true)
Line    = Struct.new(:segments, :label, :align, keyword_init: true)
Segment = Struct.new(:chord, :fret, :text, keyword_init: true)

class DSLParser
  # Groupe 2 optionnel : "-<case>" (ex. "/Bb-6:") = case (fret) explicite où jouer
  # l'accord, cohérent avec le nommage des fichiers de diag `<Accord>-<case>[-N].svg`
  # . Sans lui, sélection du diagramme au fret le plus bas ("le plus
  # en haut du manche") — voir `ChordDiagrams.diag_path`. N'IMPORTE QUOI entre "-" et ":"
  # (pas seulement des chiffres) : "le nom seul sert à trouver l'accord" (Phil,
  # 2026-08-21) — le séparateur "-" existe, ce qui le suit n'a pas besoin d'être un
  # numéro propre pour que le NOM (groupe 1) soit reconnu (bug constaté : "/g2-0C:",
  # "En rouge et noir"/"Belle île en mer", pas reconnu DU TOUT faute de `-(\d+)` strict).
  # "+" (quinte augmentée, ex. "/d75+:", "Amstrong") : absent de la classe de caractères,
  # accord jamais reconnu du tout (bug constaté).
  CHORD_RE = /\/((?:[A-Za-zÀ-ÿ0-9#♯♭+\[\]]+)(?:\/[A-Za-zÀ-ÿ0-9#♯♭+\[\]]+)?)(?:-([^: ]+))?:/

  def self.parse(source)
    new(source).parse
  end

  # "_" (accord seul en début de vers, sans mot dessous — ex. All You Need Is Love,
  # -> 3 espaces, pour l'alignement plutôt qu'un underscore imprimé.
  # Méthode de classe (toujours publique) : seule source de vérité pour le découpage
  # accord/texte d'une ligne — réutilisée telle quelle par `PageBuilder` pour le format
  # `.lyr` (plus de logique dupliquée entre les deux formats).
  # Un "/" NU dans les paroles n'a rien à faire là — c'est TOUJOURS un séparateur
  # d'accord/basse, jamais un caractère de parole réel (Phil : "un '/' n'a rien à faire
  # dans des paroles"). `\/` (échappé) reste un "/" littéral voulu par l'user, seul
  # moyen d'en écrire un vrai.
  def self.strip_bare_slashes(text)
    text.gsub(%r{\\/|/}) { |m| m == "\\/" ? "/" : "" }
  end

  def self.parse_line(line)
    line = line.gsub("_", "   ")
    segments = []
    matches = line.to_enum(:scan, CHORD_RE).map { Regexp.last_match }

    if matches.empty?
      text = strip_bare_slashes(line)
      segments << Segment.new(chord: nil, text: text) unless text.empty?
      glue_commas!(segments)
      return segments
    end

    pre = strip_bare_slashes(line[0...matches.first.begin(0)])
    segments << Segment.new(chord: nil, text: pre) unless pre.empty?

    i = 0
    while i < matches.length
      m = matches[i]
      chord = normalize_chord(m[1])
      fret = m[2]
      # "/" SEUL entre deux marqueurs collés (ex. "/F://C:") : PAS un séparateur à
      # effacer — un séparateur VISUEL entre deux accords de la MÊME mesure (jamais deux
      # syllabes distinctes), fusionnés en UN SEUL segment "F/C" (`Layout.draw_chord_label`
      # sait déjà afficher un nom d'accord avec "/", `ChordDiagrams.split_chord` déjà le
      # rescinder pour les diagrammes) — jamais gravé dans les paroles, jamais non plus
      # purement supprimé (bug constaté : perdait le lien visuel entre les deux accords,
      # rendus comme deux accords disjoints avec juste un espace).
      while i + 1 < matches.length && line[m.end(0)...matches[i + 1].begin(0)] == "/"
        i += 1
        nxt = matches[i]
        chord = "#{chord}/#{normalize_chord(nxt[1])}"
        fret ||= nxt[2]
        m = nxt
      end
      text_start = m.end(0)
      text_end = i + 1 < matches.length ? matches[i + 1].begin(0) : line.length
      segments << Segment.new(chord: chord, fret: fret, text: strip_bare_slashes(line[text_start...text_end]))
      i += 1
    end

    glue_commas!(segments)
    segments
  end

  # Une virgule reste TOUJOURS collée au mot précédent (issue #75), même si un
  # accord ("/c:_,") ou le "_" d'alignement (-> 3 espaces, ligne 39) s'intercale entre
  # les deux — sans ça, "France /c:_," rendait "France   ," (espaces visibles).
  def self.glue_commas!(segments)
    segments.each { |s| s.text.gsub!(/ +,/, ",") }
    (1...segments.length).each do |i|
      segments[i - 1].text.sub!(/ +\z/, "") if segments[i].text.start_with?(",")
    end
  end

  # Écriture en minuscule tolérée pour la commodité de frappe ("/am:") — la
  # première lettre de la fondamentale doit toujours être rendue en capitale ("Am"),
  # le reste de la qualité inchangé (ex. "m7b5"). Basse entre crochets (`A[c]m7`,
  # `Am7[c]`, `[cd]` seule, issue #60) : MÊME RÈGLE que la fondamentale — 1re lettre
  # en capitale ("[Fd]"), le reste forcé en minuscule (le 2e caractère, dièse/bémol,
  # DOIT rester minuscule : `Transpose.italian_bass_symbol` le compare tel quel à
  # "d"/"b").
  def self.normalize_chord(chord)
    chord.split("/").map do |part|
      part = part.gsub(/\[[^\]]*\]/) { |m| "[#{m[1..-2].downcase.sub(/\A./) { |c| c.upcase }}]" }
      part.start_with?("[") ? part : part.sub(/\A./) { |c| c.upcase }
    end.join("/")
  end

  def initialize(source)
    @source = source
  end

  def parse
    meta, body = split_frontmatter(@source)
    Song.new(meta: meta, blocks: parse_blocks(body))
  end

  private

  def split_frontmatter(source)
    return [{}, source] unless source.start_with?("---")

    _, fm, rest = source.split(/^---\s*$/, 3)
    [YAML.safe_load(fm.to_s) || {}, rest.to_s]
  end

  def parse_blocks(body)
    raw_blocks = body.split(/\n{2,}/).map(&:strip).reject(&:empty?)
    blocks = []
    directives = {}
    pair_next = false

    raw_blocks.each do |raw|
      if raw == "//"
        pair_next = true
        next
      end

      lines = raw.split("\n")
      if lines.first =~ /\A\{(.*)\}\z/
        directives = parse_directives($1)
        lines = lines[1..] || []
      end
      next if lines.empty?

      blocks << Block.new(
        lines: lines.map { |l| Line.new(segments: self.class.parse_line(l)) },
        directives: directives,
        paired_with_previous: pair_next
      )
      directives = {}
      pair_next = false
    end

    blocks
  end

  def parse_directives(str)
    str.split(";").each_with_object({}) do |pair, h|
      k, v = pair.split(":", 2)
      next unless k && v

      h[k.strip.to_sym] = v.strip
    end
  end
end
