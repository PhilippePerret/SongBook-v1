# Parseur du format `.cov` (mise en page de couverture, Phil 2026-08-22) :
# sections `1.`/`4.` (1re/4e de couverture), blocs séparés par ligne vide,
# directives `{nom; prop:valeur; ...}` avec repli `{a|b}` (a si présent, sinon b).
# `|` HORS des `{}`, à une colonne de caractère constante sur les lignes d'un
# bloc, sépare le bloc en 2 colonnes (gauche/droite) ALIGNÉES bloc à bloc (pas
# ligne à ligne) — voir `block_height`/résolution dans `cover_builder.rb`.
module CovParser
  Item = Struct.new(:names, :props, keyword_init: true)

  # bloc simple (une colonne, items empilés) ou bloc scindé (2 colonnes alignées)
  Block = Struct.new(:left, :right, keyword_init: true) do
    def split? = !right.nil?
  end

  def self.parse(path)
    sections = { 1 => [], 4 => [] }
    current = nil
    block_lines = []

    flush = lambda do
      next if block_lines.empty? || current.nil?

      sections[current] << parse_block(block_lines)
      block_lines = []
    end

    File.readlines(path, chomp: true).each do |line|
      if line =~ /\A(1|4)\.\s*\z/
        flush.call
        current = Regexp.last_match(1).to_i
        next
      end

      if line.strip.empty?
        flush.call
        next
      end

      block_lines << line
    end
    flush.call

    sections
  end

  # Colonne du premier `|` à profondeur d'accolade 0, ou nil si absent.
  def self.top_level_pipe(line)
    depth = 0
    line.each_char.with_index do |c, i|
      case c
      when "{" then depth += 1
      when "}" then depth -= 1
      when "|" then return i if depth.zero?
      end
    end
    nil
  end

  # `:blank` = ligne présente (avec `|`) mais sans directive d'un côté — espace
  # vertical VOULU (Phil, 2026-08-22 : sert à agrandir une image alignée en face en
  # ajoutant des lignes vides), jamais juste ignoré/sauté.
  def self.parse_block(lines)
    pipes = lines.map { |l| top_level_pipe(l) }
    if pipes.all?(&:nil?)
      Block.new(left: lines.filter_map { |l| parse_item(l) }, right: nil)
    else
      left = []
      right = []
      lines.each_with_index do |l, i|
        p = pipes[i]
        if p
          left << (parse_item(l[0...p]) || :blank)
          right << (parse_item(l[(p + 1)..]) || :blank)
        else
          left << (parse_item(l) || :blank)
        end
      end
      Block.new(left: left, right: right)
    end
  end

  # `"  {editor_logo|editor_name; align:center;}  "` -> Item
  def self.parse_item(text)
    m = text.strip.match(/\A\{(.*)\}\z/)
    return nil unless m

    segments = m[1].split(";").map(&:strip).reject(&:empty?)
    return nil if segments.empty?

    names = segments.shift.split("|").map(&:strip)
    props = segments.each_with_object({}) do |seg, h|
      k, v = seg.split(":", 2)
      h[k.strip] = v.to_s.strip if k
    end
    Item.new(names: names, props: props)
  end
end
