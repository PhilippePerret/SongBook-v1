require_relative "layout"

# Rendu minimal des sections "front matter" (préface, avant-propos, remerciements) —
# reconnaissance directe adaptée à Prawn, pas de dépendance Markdown externe (Phil,
# 2026-08-20 : un vrai parseur type Kramdown ajouterait une dépendance et une étape de
# traduction arbre -> Prawn pour un gain nul, Prawn ne consommant que du texte formaté).
# Couvre titres (#, ##, ###), paragraphes, listes (- / *) et emphase (**gras**,
# *italique*/_italique_) — suffisant pour de la prose simple, pas de tableaux/liens/images.
module MarkdownPage
  H_SIZES = { 1 => 18, 2 => 15, 3 => 13 }.freeze
  H_DEFAULT_SIZE = 12
  TEXT_SIZE = 11
  LINE_GAP = 4
  BLOCK_GAP = 10
  LIST_INDENT = 14
  BULLET = "•  "

  Block = Struct.new(:type, :level, :lines)

  def self.parse(source)
    source.split(/\n{2,}/).map(&:strip).reject(&:empty?).map do |para|
      lines = para.split("\n").map(&:strip)
      if (m = lines.first.match(/\A(\#{1,6})\s+(.*)\z/))
        Block.new(:header, m[1].length, [m[2]])
      elsif lines.all? { |l| l =~ /\A[-*]\s+/ }
        Block.new(:list, nil, lines.map { |l| l.sub(/\A[-*]\s+/, "") })
      else
        Block.new(:paragraph, nil, [lines.join(" ")])
      end
    end
  end

  # Découpe une ligne en fragments {text:, styles:} pour `formatted_text`/`height_of_formatted`
  # — reconnaît **gras** et *italique*/_italique_ (non imbriqués, suffisant ici).
  def self.inline_fragments(text, size)
    fragments = []
    text.scan(/\*\*(.+?)\*\*|\*(.+?)\*|_(.+?)_|([^*_]+)/) do |bold, italic, italic2, plain|
      if bold
        fragments << { text: bold, styles: [:bold], size: size }
      elsif italic || italic2
        fragments << { text: italic || italic2, styles: [:italic], size: size }
      else
        fragments << { text: plain, size: size }
      end
    end
    fragments
  end

  # Dessine tout le fichier `md_path` dans les bounds courantes de `pdf` (déjà margées/
  # numérotées par l'appelant), sur UNE SEULE page — pas de flux multi-page pour l'instant
  # (limitation connue, Phil 2026-08-20). Signale plutôt que de couper silencieusement si
  # le contenu déborde.
  def self.render(pdf, md_path, width)
    y = pdf.bounds.height
    parse(File.read(md_path)).each { |block| y = draw_block(pdf, block, y, width) }

    return unless y < -0.01

    Layout.conflict!("contenu Markdown (#{File.basename(md_path)}) dépasse la page de #{-y.round(2)}pt",
      solution: "dessiné quand même, hors zone sûre")
  end

  def self.draw_block(pdf, block, y, width)
    case block.type
    when :header
      size = H_SIZES.fetch(block.level, H_DEFAULT_SIZE)
      pdf.draw_text block.lines.first, at: [0, y - size], size: size, style: :bold
      y - size - BLOCK_GAP
    when :list
      block.lines.each do |line|
        fragments = inline_fragments(line, TEXT_SIZE)
        h = pdf.height_of_formatted(fragments, width: width - LIST_INDENT)
        pdf.draw_text BULLET, at: [0, y - TEXT_SIZE], size: TEXT_SIZE
        pdf.formatted_text_box fragments, at: [LIST_INDENT, y], width: width - LIST_INDENT
        y -= h + LINE_GAP
      end
      y - BLOCK_GAP + LINE_GAP
    else # :paragraph
      fragments = inline_fragments(block.lines.first, TEXT_SIZE)
      h = pdf.height_of_formatted(fragments, width: width)
      pdf.formatted_text_box fragments, at: [0, y], width: width
      y - h - BLOCK_GAP
    end
  end
end
