require "prawn"
require "shellwords"
require_relative "layout"
require_relative "kdp"
require_relative "cov_parser"
require_relative "app_config"
require_relative "locale"
require_relative "markdown_page"

# Couverture KDP complète (1re/dos/4e, un seul PDF, extérieur uniquement — la 2e/3e de
# couverture ne sont pas imprimées par ce fichier, ce sont les faces internes de la même
# feuille cartonnée, jamais transmises via le PDF de couverture KDP standard).
# Mise en page pilotée par un fichier `.cov`  — voir `CovParser`) :
# sections `1.`/`4.`, blocs, directives `{champ; prop:valeur}`, `|` = colonnes alignées
# BLOC à bloc. `align:` combine un mot horizontal (left/right/center/justify) et un mot
# vertical (top/bot) — ex. `align:Right Bot` = texte aligné à droite, calé au bas de sa
# colonne mais AU-DESSUS de tout ce qui suit dans cette même colonne (pas au bas de la
# page). `:blank` (ligne `|` sans directive d'un côté) = espace vertical voulu.
#
# Les règles esthétiques de l'intérieur régissent aussi la couverture  :
# - RATX1 : texte non-lyrics, phrases longues, page > 15cm -> 2 colonnes, gouttière
#   `text_column_guter`. `performer-list` reste un TEXTE continu (pas une liste — RATX1
#   ne dit nulle part de restructurer en liste), simplement réparti sur 2 colonnes.
# - RATX2 : police `text_font`.
# - RATX3 : texte non-lyrics justifié, sauf `align:` explicite dans le `.cov`.
# Sur la 4e de couverture, les BLOCS (pas le texte à l'intérieur) sont centrés
# horizontalement — convention traditionnelle de 4e.
# `code_barres` (dernier bloc de la 4e) ancré sur la vraie position de `kdp.barcode_zone`
# — jamais un simple flux séquentiel comme le reste. Les autres blocs d'une section se
# répartissent avec un espacement égal sur tout l'espace disponible (au-dessus de cette
# ancre côté 4e) plutôt que de s'entasser en haut en laissant un vide en bas.
module CoverBuilder
  ITEM_GAP = 4.0
  BLOCK_GAP = 16.0
  IMAGE_TEXT_GAP = 12.0
  DEFAULT_FONT_SIZE = 11.0
  BLANK_LINE_H = 12.0
  STANDALONE_IMAGE_MAX_H = 26.0 # logo etc. : discret, jamais plus gros que le texte voisin.
  MIN_SCALE = 0.55

  # Marge de reliure (spirale, "vrais" carnets de chant) — mange sur 1re ET 4e, bord
  # HAUT (format paysage retenu pour ce projet -> reliure façon bloc-notes/flip, pas sur
  # le côté). Valeur provisoire (Phil, aucune mesure réelle encore fournie).
  BINDING_MARGIN_IN = 0.75

  DEBUG_COLOR = "99CCEE"

  def self.build(out_path, cov_path:, kdp:, conf:, entries:, carnet_folder:, debug_marks: false)
    cw = Layout.in_pt(kdp.cover_width)
    ch = Layout.in_pt(kdp.cover_height)
    bleed = Layout.in_pt(KDP::BLEED_IN)
    spine_w = Layout.in_pt(kdp.spine_width)
    trim_w_pt = Layout.in_pt(kdp.trim_width)
    safe = Layout.in_pt(kdp.cover_text_safe_margin)
    binding = conf.dig("cover", "binding") ? Layout.in_pt(BINDING_MARGIN_IN) : 0

    back_x0 = bleed
    spine_x0 = bleed + trim_w_pt
    spine_x1 = spine_x0 + spine_w
    front_x0 = spine_x1
    front_x1 = cw - bleed

    sections = CovParser.parse(cov_path)
    top_y = ch - bleed - safe - binding
    bottom_y = bleed + safe

    Prawn::Document.generate(out_path, page_size: [cw, ch], margin: 0) do |pdf|
      Layout.register_fonts(pdf)
      font_name = AppConfig.get("text_font")
      spacing = font_name.to_s.include?("Garamond") ? MarkdownPage::GARAMOND_LETTER_SPACING : 0
      pdf.fill_color "000000"

      pdf.font(font_name) do
        pdf.character_spacing(spacing) do
          ctx1 = Ctx.new(pdf, carnet_folder, conf, entries, center_blocks: false)
          render_section(ctx1, sections[1], front_x0 + safe, front_x1 - safe, top_y, bottom_y, nil)

          ctx4 = Ctx.new(pdf, carnet_folder, conf, entries, center_blocks: true)
          render_section(ctx4, sections[4], back_x0 + safe, spine_x0 - safe, top_y, bottom_y, kdp)
        end
      end

      if debug_marks
        pdf.stroke_color DEBUG_COLOR
        pdf.line_width 0.4
        pdf.stroke_rectangle [front_x0 + safe, top_y], (front_x1 - safe) - (front_x0 + safe), top_y - bottom_y
        pdf.stroke_rectangle [back_x0 + safe, top_y], (spine_x0 - safe) - (back_x0 + safe), top_y - bottom_y
        bz = kdp.barcode_zone
        pdf.stroke_rectangle [Layout.in_pt(bz[:x0]), Layout.in_pt(bz[:y1])],
          Layout.in_pt(bz[:x1] - bz[:x0]), Layout.in_pt(bz[:y1] - bz[:y0])
        pdf.stroke_color "000000"
      end
    end
    out_path
  end

  Ctx = Struct.new(:pdf, :carnet_folder, :conf, :entries, :center_blocks)

  # Un bloc contenant `code_barres` (4e seulement) est ancré sur la position RÉELLE de
  # `kdp.barcode_zone`, jamais sur le flux séquentiel — les autres blocs de la section se
  # répartissent avec un espacement égal dans l'espace qui reste au-dessus (Phil :
  # "pourquoi les règles d'équilibrage ne sont-elles appliquées nulle part").
  def self.render_section(ctx, blocks, x0, x1, top_y, bottom_y, kdp)
    barcode_idx = kdp && blocks.index { |b| block_names(b).include?("code_barres") }
    anchor_block = barcode_idx ? blocks[barcode_idx] : nil
    flow_blocks = barcode_idx ? blocks.each_with_index.reject { |_, i| i == barcode_idx }.map(&:first) : blocks

    anchor_top = top_y
    if anchor_block
      bz = kdp.barcode_zone
      anchor_h = [render_block(ctx, anchor_block, x0, x1, 0, scale: 1.0, dry: true), Layout.in_pt(bz[:y1] - bz[:y0])].max
      anchor_top = Layout.in_pt(bz[:y1])
      render_block(ctx, anchor_block, x0, x1, anchor_top, scale: 1.0, dry: false, forced_h: anchor_h)
      anchor_top -= BLOCK_GAP
    end

    natural = flow_blocks.map { |b| render_block(ctx, b, x0, x1, 0, scale: 1.0, dry: true) }
    n_gaps = [flow_blocks.size - 1, 0].max
    natural_total = natural.sum + n_gaps * BLOCK_GAP
    available = top_y - (anchor_block ? anchor_top : bottom_y)
    scale = (natural_total.positive? && natural_total > available) ? [available / natural_total, MIN_SCALE].max : 1.0

    final = flow_blocks.map { |b| render_block(ctx, b, x0, x1, 0, scale: scale, dry: true) }
    used = final.sum + n_gaps * BLOCK_GAP * scale
    slack = [available - used, 0].max
    extra_gap = n_gaps.positive? ? slack / n_gaps : 0

    y = top_y
    flow_blocks.each do |block|
      h = render_block(ctx, block, x0, x1, y, scale: scale, dry: false)
      y -= h + BLOCK_GAP * scale + extra_gap
    end
  end

  def self.block_names(block)
    items = block.left + (block.right || [])
    items.reject { |it| it == :blank }.flat_map(&:names)
  end

  def self.render_block(ctx, block, x0, x1, y_top, scale:, dry:, forced_h: nil)
    unless block.split?
      return stack_items(ctx, block.left, x0, x1, y_top, scale, dry, container_h: forced_h, center: ctx.center_blocks)
    end

    left_img = lone_image?(ctx, block.left, x0, x1)
    right_img = lone_image?(ctx, block.right, x0, x1)

    if left_img || right_img
      render_split_with_image(ctx, block, x0, x1, y_top, left_img, scale: scale, dry: dry)
    else
      render_split_plain(ctx, block, x0, x1, y_top, scale: scale, dry: dry, forced_h: forced_h)
    end
  end

  # Bloc scindé où un des 2 côtés est une image SEULE : l'image se cale sur la hauteur
  # RÉELLE de l'autre colonne (texte + éventuels `:blank` = espace voulu) — jamais une
  # hauteur de page devinée. Pour une image "presque pleine page", le `.cov` ajoute des
  # lignes `|` vides dans la colonne texte  ; pour une image calée sur
  # le seul titre, la colonne texte ne contient que le titre — LE `.cov` DÉCIDE, pas une
  # heuristique de comptage de blocs (erreur commise puis corrigée dans la même session).
  # Alignée sur le bord EXTÉRIEUR de sa colonne (Phil : "la guitare à gauche"). L'autre
  # côté peut contenir un item `align:...Bot` (ex. `author|book_designer`, ou un logo sans
  # indication) : calé en bas DE SA COLONNE, au-dessus de ce qui suit.
  def self.render_split_with_image(ctx, block, x0, x1, y_top, left_img, scale:, dry:)
    text_items = left_img ? block.right : block.left
    text_total = stack_items(ctx, text_items, x0, x1, 0, scale, true, container_h: nil, center: false)
    block_h = [text_total, 0.001].max

    img_item = (left_img ? block.left : block.right).find { |it| it != :blank }
    _, (path, img_w), _img_h = item_dimensions(ctx, img_item, x0, x1, target_h: block_h)

    if left_img
      img_x0 = x0
      text_x0 = x0 + img_w + IMAGE_TEXT_GAP
      text_x1 = x1
    else
      img_x0 = x1 - img_w
      text_x0 = x0
      text_x1 = x1 - img_w - IMAGE_TEXT_GAP
    end

    unless dry
      render_item(ctx, img_item, img_x0, img_x0 + img_w, y_top, scale: scale, dry: false, target_h: block_h, left_align: left_img)
    end

    stack_items(ctx, text_items, text_x0, text_x1, y_top, scale, dry, container_h: block_h, center: false)

    block_h
  end

  # Bloc scindé classique (aucun côté n'est une image seule) : 2 colonnes de largeur
  # égale, chaque côté centré sur la hauteur du bloc (le plus grand des deux).
  def self.render_split_plain(ctx, block, x0, x1, y_top, scale:, dry:, forced_h: nil)
    gap = IMAGE_TEXT_GAP * scale
    lw = (x1 - x0 - gap) / 2.0
    l_x0, l_x1 = x0, x0 + lw
    r_x0, r_x1 = x0 + lw + gap, x1

    left_total = stack_items(ctx, block.left, l_x0, l_x1, 0, scale, true, container_h: nil, center: false)
    right_total = stack_items(ctx, block.right, r_x0, r_x1, 0, scale, true, container_h: nil, center: false)
    block_h = forced_h || [left_total, right_total, 0.001].max

    y = y_top - (block_h - left_total) / 2.0
    stack_items(ctx, block.left, l_x0, l_x1, y, scale, dry, container_h: nil, center: false)

    y = y_top - (block_h - right_total) / 2.0
    stack_items(ctx, block.right, r_x0, r_x1, y, scale, dry, container_h: nil, center: false)

    block_h
  end

  # Empile les items d'UNE colonne. `container_h`, si fourni, fixe la hauteur totale du
  # bloc : un item `align:...Bot` reçoit alors tout l'espace mou (slack) juste AVANT lui —
  # calé en bas de sa colonne, au-dessus de tout ce qui le suit .
  # `center` : bloc entier (pas le texte dedans) centré horizontalement dans [x0,x1]
  # (convention 4e de couverture).
  def self.stack_items(ctx, items, x0, x1, y_top, scale, dry, container_h:, center:)
    return 0 if items.nil? || items.empty?

    dims = items.map { |it| it == :blank ? [nil, nil, BLANK_LINE_H * scale] : item_dimensions(ctx, it, x0, x1) }
    natural_total = dims.sum { |_, _, h| h } + ITEM_GAP * scale * [items.size - 1, 0].max
    slack = container_h ? [container_h - natural_total, 0].max : 0
    anchor_idx = items.index { |it| it != :blank && parse_align(it).last == :bottom }
    # Sans indication explicite : le DERNIER item réel d'une colonne se comporte comme
    # `Bot` par défaut — un logo/élément qui ne précède rien d'autre va naturellement en
    # bas, pas collé à ce qui le précède  : "un logo ne se place JAMAIS
    # sous le bloc de texte"). Le premier reste en haut par le flux normal, sans réglage.
    anchor_idx ||= items.rindex { |it| it != :blank }

    y = y_top
    items.each_with_index do |item, i|
      y -= slack if anchor_idx && i == anchor_idx
      kind, payload, h = dims[i]
      draw(ctx.pdf, kind, payload, x0, x1, y, false) if item != :blank && !dry && h.positive?
      y -= h
      y -= ITEM_GAP * scale unless i == items.size - 1
    end

    container_h || natural_total
  end

  # --- Résolution des champs -------------------------------------------------------

  def self.field_value(name, conf)
    case name
    when "title" then conf["title"]
    when "subtitle" then conf["subtitle"]
    when "author" then conf["author"]
    when "book_designer" then conf.dig("credits", "book_designer")
    when "editor_name" then conf.dig("editor", "name")
    when "editor_logo" then conf.dig("editor", "logo")
    when "cover_image" then conf.dig("cover", "image")
    when "price" then conf["price"]
    when "isbn" then conf["isbn"]
    end
  end

  SPECIAL_NAMES = %w[performer-list song-list code_barres].freeze
  LABELED_NAMES = %w[price isbn book_designer].freeze
  H_ALIGNS = %w[left right center justify].freeze
  V_ALIGNS = %w[top bot bottom].freeze

  def self.image_path?(value)
    value.to_s =~ /\.(png|jpe?g|svg)\z/i
  end

  def self.resolve_name(item, conf, entries)
    item.names.find do |n|
      next true if SPECIAL_NAMES.include?(n) && special_present?(n, entries)

      v = field_value(n, conf)
      v && !v.to_s.strip.empty?
    end
  end

  def self.special_present?(name, entries)
    case name
    when "performer-list" then entries.any? { |e| !e[:performer].to_s.empty? }
    when "song-list" then entries.any?
    when "code_barres" then false # zone réservée mais vide tant qu'aucun ISBN propre 
    end
  end

  def self.labeled_text(name, val)
    key = { "price" => "cover_price", "isbn" => "cover_isbn", "book_designer" => "cover_designed_by" }.fetch(name)
    tmpl = Loc.get(key)
    tmpl.include?("%s") ? format(tmpl, val) : "#{tmpl} #{val}"
  end

  # `align:` = "[left|right|center|justify] [top|bot|bottom]", dans n'importe quel
  # ordre/casse, les 2 mots optionnels. RATX3 : justify par défaut.
  def self.parse_align(item)
    return [:justify, nil] if item == :blank

    tokens = (item.props["align"] || "").to_s.downcase.split(/\s+/)
    h = (tokens.find { |t| H_ALIGNS.include?(t) } || "justify").to_sym
    v = tokens.find { |t| V_ALIGNS.include?(t) }
    v = "bottom" if v == "bot"
    [h, v&.to_sym]
  end

  # --- Mesure/dessin -----------------------------------------------------------------

  def self.item_dimensions(ctx, item, x0, x1, target_h: nil)
    return [nil, nil, 0] if item == :blank

    name = resolve_name(item, ctx.conf, ctx.entries)
    return [nil, nil, 0] unless name

    return special_item_dimensions(ctx, item, name, x0, x1) if SPECIAL_NAMES.include?(name)

    val = field_value(name, ctx.conf)
    return [nil, nil, 0] if val.nil? || val.to_s.strip.empty?

    if image_path?(val)
      image_dimensions(ctx.carnet_folder, val, x0, x1, target_h)
    else
      text = LABELED_NAMES.include?(name) ? labeled_text(name, val) : val.to_s
      size = font_size(item, DEFAULT_FONT_SIZE)
      align, = parse_align(item)
      [:text, [text, size, align, item], ctx.pdf.height_of(text, width: x1 - x0, size: size)]
    end
  end

  def self.image_dimensions(carnet_folder, val, x0, x1, target_h)
    path = File.join(carnet_folder, val)
    return [nil, nil, 0] unless File.exist?(path)

    w0, h0 = image_wh(path)
    aspect = h0 / w0.to_f
    if target_h
      h = target_h
      w = h / aspect
      if w > (x1 - x0)
        w = x1 - x0
        h = w * aspect
      end
    else
      h = STANDALONE_IMAGE_MAX_H
      w = h / aspect
      if w > (x1 - x0)
        w = x1 - x0
        h = w * aspect
      end
    end
    [:image, [path, w, h], h]
  end

  # RATX1 : `performer-list` reste un TEXTE continu (comma-séparé), simplement réparti
  # sur 2 colonnes en coupant près du milieu — jamais restructuré en liste (Phil,
  # 2026-08-22 : "RATX1 n'a jamais dit qu'il fallait transformer le texte en liste").
  # `song-list` reste une vraie liste (chaque titre = une entrée), colonnes du `.cov`.
  # Gouttière = `text_column_guter` (RATX1). Largeur de colonne = besoin réel, jamais
  # étirée pour remplir l'espace.
  def self.special_item_dimensions(ctx, item, name, x0, x1)
    case name
    when "performer-list"
      names = ctx.entries.map { |e| e[:performer] }.reject { |p| p.nil? || p.to_s.empty? }.uniq
      return [nil, nil, 0] if names.empty?

      prose_columns_dimensions(ctx.pdf, item, names.join(", "), 2, x0, x1)
    when "song-list"
      cols = [(item.props["column"] || "1").to_i, 1].max
      texts = ctx.entries.map { |e| e[:name] }
      list_columns_dimensions(ctx.pdf, item, texts, cols, x0, x1)
    when "code_barres"
      [nil, nil, 0]
    end
  end

  def self.list_columns_dimensions(pdf, item, texts, cols, x0, x1)
    return [nil, nil, 0] if texts.empty?

    size = font_size(item, 8.0)
    align, = parse_align(item)
    gutter = AppConfig.length_pt(AppConfig.get("text_column_guter"))

    chunk = [(texts.size / cols.to_f).ceil, 1].max
    columns = texts.each_slice(chunk).map { |c| c.join("\n") }

    natural_w = texts.map { |t| pdf.width_of(t, size: size) }.max || 0
    max_allowed = (x1 - x0 - (cols - 1) * gutter) / cols
    col_w = [natural_w, max_allowed].min

    max_h = columns.map { |t| pdf.height_of(t, width: col_w, size: size) }.max || 0
    [:column_list, [col_w, gutter, size, align, columns], max_h]
  end

  # Coupe `text` en 2 (près du milieu, à la frontière mot/virgule la plus proche) —
  # chaque moitié reste un texte continu qui se justifie/wrap normalement dans sa colonne
  # (PAS une liste : pas de découpe item par item).
  def self.prose_columns_dimensions(pdf, item, text, cols, x0, x1)
    size = font_size(item, 8.0)
    align, = parse_align(item)
    gutter = AppConfig.length_pt(AppConfig.get("text_column_guter"))
    col_w = (x1 - x0 - (cols - 1) * gutter) / cols

    mid = text.length / 2
    m = text.match(/,\s|\s/, mid)
    cut = m ? m.end(0) : text.length
    parts = [text[0...cut].strip, text[cut..].to_s.strip]

    max_h = parts.map { |t| pdf.height_of(t, width: col_w, size: size) }.max || 0
    [:column_list, [col_w, gutter, size, align, parts], max_h]
  end

  # Une colonne scindée peut contenir des `:blank` (lignes `|` vides côté image, servant
  # à donner de la hauteur à l'AUTRE colonne —  : on ne compte que les
  # items RÉELS pour décider si cette colonne est une image seule.
  def self.lone_image?(ctx, items, x0, x1)
    real = items&.reject { |it| it == :blank }
    real && real.size == 1 && item_dimensions(ctx, real.first, x0, x1).first == :image
  end

  def self.font_size(item, default)
    return default if item == :blank

    (item.props["font-size"] || "#{default}pt").to_f
  end

  def self.image_wh(path)
    if path.downcase.end_with?(".svg")
      content = File.read(path)
      m = content.match(/viewBox\s*=\s*"[\d.\-]+\s+[\d.\-]+\s+([\d.]+)\s+([\d.]+)"/)
      m ? [m[1].to_f, m[2].to_f] : [1.0, 1.0]
    else
      out = `magick identify -format "%w %h" #{Shellwords.escape(path)}`
      w, h = out.split.map(&:to_f)
      [w.positive? ? w : 1.0, h.positive? ? h : 1.0]
    end
  end

  # --- Dessin réel (appelé seulement quand dry: false) --------------------------------

  def self.render_item(ctx, item, x0, x1, y_top, scale:, dry:, target_h: nil, left_align: false)
    kind, payload, h = item_dimensions(ctx, item, x0, x1, target_h: target_h)
    return 0 if kind.nil? || h <= 0
    return h if dry

    draw(ctx.pdf, kind, payload, x0, x1, y_top, left_align)
    h
  end

  def self.draw(pdf, kind, payload, x0, x1, y_top, left_align)
    case kind
    when :text
      text, size, align, = payload
      pdf.text_box text, at: [x0, y_top], width: x1 - x0, size: size, align: align
    when :image
      path, w, h = payload
      cx = left_align ? x0 : x0 + (x1 - x0 - w) / 2.0
      if path.downcase.end_with?(".svg")
        # `width:` SEUL ne suffit pas : les SVG avec `width="100%" height="100%"` (ex.
        # logo.svg) font retomber prawn-svg sur la hauteur de PAGE, pas l'aspect du
        # viewBox (bug trouvé par test isolé, 2026-08-22) — `height:` doit être explicite.
        pdf.svg(IO.read(path), at: [cx, y_top], width: w, height: h, position: :left, enable_web_requests: false)
      else
        pdf.image(path, at: [cx, y_top], width: w)
      end
    when :column_list
      col_w, gutter, size, align, texts = payload
      total_w = texts.size * col_w + [texts.size - 1, 0].max * gutter
      ox = x0 + [(x1 - x0 - total_w) / 2.0, 0].max
      texts.each_with_index do |t, i|
        cx = ox + i * (col_w + gutter)
        pdf.text_box t, at: [cx, y_top], width: col_w, size: size, align: align
      end
    end
  end
end
