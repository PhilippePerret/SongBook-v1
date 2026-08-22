require_relative "layout"
require_relative "app_options"

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
  # RATX1 (Manuel/regles_esthetiques.adoc) : texte autre que lyrics, à phrases longues,
  # sur 2 colonnes dès que la page dépasse 15cm de large — gouttière fixe (`text_column_guter`,
  # options.yaml).
  TWO_COL_THRESHOLD_PT = AppOptions.length_pt("15cm")

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
  # (limitation connue, Phil 2026-08-20). RATX1 : 2 colonnes si `width` > 15cm. RATX2 :
  # police dédiée (`text_font`, options.yaml), différente de celle des lyrics.
  # Garamond (quelle que soit la variante — `Garamond`, `Cormorant_Garamond`) rendu trop
  # serré en prose longue (préface, avant-propos...) — Phil, 2026-08-21 : "écarter un peu
  # les lettres". Valeur provisoire, jamais validée par Phil.
  GARAMOND_LETTER_SPACING = 0.15

  def self.render(pdf, md_path, width, top: pdf.bounds.height)
    blocks = parse(File.read(md_path))
    text_font_name = AppOptions.get("text_font")
    spacing = text_font_name.include?("Garamond") ? GARAMOND_LETTER_SPACING : 0
    pdf.font(text_font_name) do
      pdf.character_spacing(spacing) do
        if width > TWO_COL_THRESHOLD_PT
          render_two_columns(pdf, blocks, top, width)
        else
          y = top
          blocks.each { |block| y = draw_block(pdf, block, 0, y, width) }
        end
      end
    end
  end

  def self.render_two_columns(pdf, blocks, top, width)
    gutter = AppOptions.length_pt(AppOptions.get("text_column_guter"))
    col_w = (width - gutter) / 2.0
    x = [0, col_w + gutter]
    col = 0
    y = top
    blocks.each do |block|
      h = block_height(pdf, block, col_w)
      if col.zero? && y - h < 0
        col = 1
        y = top
      end
      y = draw_block(pdf, block, x[col], y, col_w)
    end
  end

  # Hauteur qu'occuperait `block` (dont l'espace après, `BLOCK_GAP`) — calcul PUR, aucun
  # dessin, sert à décider AVANT de dessiner s'il faut changer de colonne.
  def self.block_height(pdf, block, width)
    case block.type
    when :header
      H_SIZES.fetch(block.level, H_DEFAULT_SIZE) + BLOCK_GAP
    when :list
      total = block.lines.sum { |line| pdf.height_of_formatted(inline_fragments(line, TEXT_SIZE), width: width - LIST_INDENT) + LINE_GAP }
      total + BLOCK_GAP - LINE_GAP
    else
      pdf.height_of_formatted(inline_fragments(block.lines.first, TEXT_SIZE), width: width) + BLOCK_GAP
    end
  end

  def self.draw_block(pdf, block, x, y, width)
    case block.type
    when :header
      size = H_SIZES.fetch(block.level, H_DEFAULT_SIZE)
      descent = Layout.font_metric(pdf, size) { pdf.font.descender }
      Layout.engrave(bottom: y - size - descent, context: "titre Markdown") { pdf.draw_text block.lines.first, at: [x, y - size], size: size, style: :bold }
      y - size - BLOCK_GAP
    when :list
      bullet_descent = Layout.font_metric(pdf, TEXT_SIZE) { pdf.font.descender }
      block.lines.each do |line|
        fragments = inline_fragments(line, TEXT_SIZE)
        h = pdf.height_of_formatted(fragments, width: width - LIST_INDENT)
        Layout.engrave(bottom: [y - TEXT_SIZE - bullet_descent, y - h].min, context: "liste Markdown") do
          pdf.draw_text BULLET, at: [x, y - TEXT_SIZE], size: TEXT_SIZE
          # RATX3 : justifié (Manuel/regles_esthetiques.adoc), comme le reste des textes
          # hors lyrics.
          pdf.formatted_text_box fragments, at: [x + LIST_INDENT, y], width: width - LIST_INDENT, align: :justify
        end
        y -= h + LINE_GAP
      end
      y - BLOCK_GAP + LINE_GAP
    else # :paragraph
      fragments = inline_fragments(block.lines.first, TEXT_SIZE)
      h = pdf.height_of_formatted(fragments, width: width)
      # RATX3 : justifié.
      Layout.engrave(bottom: y - h, context: "paragraphe Markdown") { pdf.formatted_text_box fragments, at: [x, y], width: width, align: :justify }
      y - h - BLOCK_GAP
    end
  end
end
