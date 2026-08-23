require "yaml"

Song    = Struct.new(:meta, :blocks, keyword_init: true)
Block   = Struct.new(:lines, :directives, :paired_with_previous, keyword_init: true)
Line    = Struct.new(:segments, :label, :align, keyword_init: true)
Segment = Struct.new(:chord, :fret, :text, keyword_init: true)

class DSLParser
  # Groupe 2 optionnel : "-<case>" (ex. "/Bb-6:") = case (fret) explicite où jouer
  # l'accord, cohérent avec le nommage des fichiers de diag `<Accord>-<case>[-N].svg`
  # (Phil, 2026-08-18). Sans lui, sélection du diagramme au fret le plus bas ("le plus
  # en haut du manche") — voir `ChordDiagrams.diag_path`. N'IMPORTE QUOI entre "-" et ":"
  # (pas seulement des chiffres) : "le nom seul sert à trouver l'accord" (Phil,
  # 2026-08-21) — le séparateur "-" existe, ce qui le suit n'a pas besoin d'être un
  # numéro propre pour que le NOM (groupe 1) soit reconnu (bug constaté : "/g2-0C:",
  # "En rouge et noir"/"Belle île en mer", pas reconnu DU TOUT faute de `-(\d+)` strict).
  CHORD_RE = /\/((?:[A-Za-zÀ-ÿ0-9#♯♭]+)(?:\/[A-Za-zÀ-ÿ0-9#♯♭]+)?)(?:-([^: ]+))?:/

  def self.parse(source)
    new(source).parse
  end

  # "_" (accord seul en début de vers, sans mot dessous — ex. All You Need Is Love,
  # Phil 2026-08-17) -> 3 espaces, pour l'alignement plutôt qu'un underscore imprimé.
  # Méthode de classe (toujours publique) : seule source de vérité pour le découpage
  # accord/texte d'une ligne — réutilisée telle quelle par `PageBuilder` pour le format
  # `.lyr` (plus de logique dupliquée entre les deux formats).
  def self.parse_line(line)
    line = line.gsub("_", "   ")
    segments = []
    matches = line.to_enum(:scan, CHORD_RE).map { Regexp.last_match }

    if matches.empty?
      segments << Segment.new(chord: nil, text: line) unless line.empty?
      return segments
    end

    pre = line[0...matches.first.begin(0)]
    segments << Segment.new(chord: nil, text: pre) unless pre.empty?

    matches.each_with_index do |m, i|
      text_start = m.end(0)
      text_end = i + 1 < matches.length ? matches[i + 1].begin(0) : line.length
      segments << Segment.new(chord: normalize_chord(m[1]), fret: m[2], text: line[text_start...text_end])
    end

    segments
  end

  # Écriture en minuscule tolérée pour la commodité de frappe ("/am:") — la
  # première lettre de chaque note (fondamentale, basse) doit toujours être
  # rendue en capitale ("Am"), le reste de la qualité inchangé (ex. "m7b5").
  def self.normalize_chord(chord)
    chord.split("/").map { |part| part.sub(/\A./) { |c| c.upcase } }.join("/")
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
