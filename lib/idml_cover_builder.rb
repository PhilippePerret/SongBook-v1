require "idml"
require "fileutils"
require "shellwords"
require "pathname"
require_relative "text_outliner"

# Gabarit de couverture IDML (importable dans Affinity Publisher / InDesign),
# 2026-08-22 : mise en page automatique abandonnée. Ce module produit des CADRES
# NOMMÉS, un par champ connu, répartis pour ne jamais se chevaucher — l'humain termine
# la mise en page dans Affinity/InDesign.
#
# UNE SEULE maquette (4e + dos + 1re côte à côte), pas 2 pages séparées (Phil,
# 2026-08-22) — même géométrie que `CoverBuilder`/`PrinterProfile#cover_width` (PDF), page =
# feuille complète bleed inclus. Bleed en CARACTÉRISTIQUE DU DOCUMENT
# (`DocumentPreference` bleed offsets, `Resources/Preferences.xml`) — Affinity/InDesign
# affichent le repère de rognage automatiquement, pas besoin de traits dessinés.
#
# Base structurelle : parties non modifiées d'un IDML RÉEL généré par Adobe
# (`assets/idml_template/`, vendu depuis `helloworld-1.idml` du gem `idml`) — réduit le
# risque de fichier invalide. `designmap.xml`, `Resources/Preferences.xml`,
# `Spreads/*.xml`, `Stories/*.xml` sont générés ici.
module IdmlCoverBuilder
  TEMPLATE_DIR = File.expand_path("../assets/idml_template", __dir__)
  DOM_VERSION = "13.0"

  FRAME_GAP = 10.0
  LOGO_FRAME_H = 40.0
  COVER_IMAGE_FRAME_H = 200.0
  TEXT_FRAME_H = 24.0
  CHAR_WIDTH_FACTOR = 0.55 # largeur moyenne d'un caractère ≈ 0.55 × corps, police proportionnelle
  TEXT_WIDTH_SCALE = 0.5 #  : blocs de texte réduits d'au moins 50% (largeur, pas hauteur).

  FONT_SIZE = {
    "title" => 32.0, "subtitle" => 20.0, "author" => 13.0,
    "price" => 15.0, "isbn" => 12.0, "performers" => 11.0, "songs" => 11.0,
  }.freeze

  # Titre/sous-titre/auteur en contours vectoriels  : cadre "qui
  # s'étire comme un dessin" — vérifié : c'est du texte converti en contours dans
  # InDesign, pas un type de cadre. `TextOutliner`/`GlyphOutline` reproduisent la
  # conversion). Police : seule testée/vérifiée avec les accents français composites.
  OUTLINE_FIELDS = %w[title subtitle author].freeze
  OUTLINE_FONT = File.expand_path("../assets/fonts/HelveticaNeue/HelveticaNeue-Bold.ttf", __dir__)

  # Bloc de renforcement de reliure  : "sur les vrais carnets, c'est un
  # renforcement de la reliure") — couvre le dos, déborde de 2cm sur 1re et 4e. Gris
  # foncé, VERROUILLÉ (`Locked="true"`) pour ne pas être déplacé par erreur.
  BINDING_OVERLAP_CM = 2.0
  BINDING_COLOR = "Color/DarkGray"

  Field = Struct.new(:name, :kind, :resolver, keyword_init: true)

  # `cover_image` placé À PART (bord de la reliure), plus dans l'empilement — les 3
  # textes + logo se centrent verticalement dans l'espace restant .
  COVER_IMAGE_FIELD = Field.new(name: "cover_image", kind: :image, resolver: ->(conf, _e) { conf.dig("cover", "image") })

  FRONT_FIELDS = [
    Field.new(name: "title", kind: :text, resolver: ->(conf, _e) { conf["title"] }),
    Field.new(name: "subtitle", kind: :text, resolver: ->(conf, _e) { conf["subtitle"] }),
    Field.new(name: "author", kind: :text, resolver: ->(conf, _e) { conf["author"] || conf.dig("credits", "book_designer") }),
    Field.new(name: "editor_logo", kind: :image, resolver: ->(conf, _e) { conf.dig("editor", "logo") }),
  ].freeze

  BACK_FIELDS = [
    Field.new(name: "performers", kind: :text, resolver: lambda { |_conf, entries|
      names = entries.map { |e| e[:performer] }.reject { |p| p.nil? || p.to_s.empty? }.uniq
      names.empty? ? nil : names.join(", ")
    }),
    Field.new(name: "songs", kind: :text, resolver: lambda { |_conf, entries|
      titles = entries.map { |e| e[:name] }
      titles.empty? ? nil : titles.join("\n")
    }),
    Field.new(name: "isbn", kind: :text, resolver: ->(conf, _e) { conf["isbn"] && "ISBN : #{conf["isbn"]}" }),
    Field.new(name: "price", kind: :text, resolver: ->(conf, _e) { conf["price"] && "Prix : #{conf["price"]}" }),
  ].freeze

  def self.build(out_path, conf:, entries:, carnet_folder:, printer:)
    bleed = printer.class::BLEED_IN * 72.0
    # Marges intérieures du carnet (pas la marge cover de l'imprimeur) — alignement visuel
    # avec les pages du livre , uniforme sur les 4 côtés (pas de recto/verso
    # sur une couverture).
    margin = printer.outside_margin * 72.0
    trim_w = printer.trim_width * 72.0
    spine_w = printer.spine_width * 72.0
    cw = printer.cover_width * 72.0
    ch = printer.cover_height * 72.0

    back_x0 = bleed
    spine_x0 = bleed + trim_w
    spine_x1 = spine_x0 + spine_w
    front_x0 = spine_x1
    front_x1 = cw - bleed

    ids = IdCounter.new
    parts = base_parts
    parts["Resources/Preferences.xml"] = preferences_xml(parts["Resources/Preferences.xml"], cw, ch, bleed)
    parts["Resources/Graphic.xml"] = add_binding_swatch(parts["Resources/Graphic.xml"])

    page_self = ids.next!
    frames = []
    stories = []

    binding_overlap = BINDING_OVERLAP_CM * 28.35
    frames << binding_frame(ids, spine_x0, spine_x1, ch, binding_overlap)
    frames << spine_outline_frame(ids, spine_x0, spine_x1, ch)

    # `cover_image` au bord de la reliure (côté 1re) — indépendante du texte, qui se
    # centre sur TOUTE la largeur de la page hors marge, sans tenir compte de l'image
    #  : "je m'en fous de l'image, ça n'a rien à voir").
    image_value = COVER_IMAGE_FIELD.resolver.call(conf, entries)
    if image_value && !image_value.to_s.strip.empty?
      img_x0 = spine_x1 + binding_overlap
      img_path = File.expand_path(image_value, carnet_folder)
      img_h = (ch - margin) - margin
      img_w = image_frame_width(img_path, front_x1 - margin - img_x0, img_h)
      frames << { kind: :image, self: ids.next!, name: "cover_image", x: img_x0, y: margin, w: img_w, h: img_h, image_path: img_path }
    end

    fx = place_fields(ids, FRONT_FIELDS, conf, entries, carnet_folder, front_x0 + margin, front_x1 - margin, margin, ch - margin)
    frames.concat(fx[:frames])
    stories.concat(fx[:stories])

    bx = place_fields(ids, BACK_FIELDS, conf, entries, carnet_folder, back_x0 + margin, spine_x0 - margin, margin, ch - margin)
    frames.concat(bx[:frames])
    stories.concat(bx[:stories])

    # Chemin RELATIF au fichier .idml lui-même  : "signalement d'une
    # ressource manquante... le chemin est '../../images/guitare.png'" — Affinity résout
    # `LinkResourceURI` par rapport à l'emplacement du .idml, pas un chemin absolu `file:`
    # ni un dossier `Links/` interne au zip, deux essais précédents qui ont échoué).
    out_dir = Pathname.new(File.dirname(File.expand_path(out_path)))
    frames.each do |f|
      next unless f[:kind] == :image

      f[:link_uri] = Pathname.new(f[:image_path]).relative_path_from(out_dir).to_s
    end

    page = { self: page_self, frames: frames }
    parts["Spreads/Spread_#{page_self}.xml"] = spread_xml(page, cw, ch)
    stories.each { |s| parts["Stories/Story_#{s[:self]}.xml"] = story_xml(s) }

    parts["designmap.xml"] = designmap_xml(stories.map { |s| s[:self] }, [page])

    FileUtils.mkdir_p(File.dirname(out_path))
    File.delete(out_path) if File.exist?(out_path)
    Idml::Package.write(parts: parts, to: out_path)
    out_path
  end

  class IdCounter
    def initialize
      @n = 0
    end

    def next!
      @n += 1
      "cv#{@n.to_s(36)}"
    end
  end

  def self.base_parts
    parts = {}
    Dir.glob(File.join(TEMPLATE_DIR, "**", "*")).each do |path|
      next if File.directory?(path)
      next if File.basename(path) == ".DS_Store"

      rel = path.sub("#{TEMPLATE_DIR}/", "")
      parts[rel] = File.binread(path)
    end
    parts
  end

  # Bleed en caractéristique du document : `PageWidth`/`PageHeight` = feuille complète
  # (bleed inclus), `DocumentBleed*Offset` = valeur du bleed — InDesign/Affinity dessinent
  # le repère de rognage automatiquement à cette distance du bord, pas besoin de traits.
  def self.preferences_xml(template_content, w, h, bleed)
    template_content
      .sub(/PageWidth="[^"]*"/, "PageWidth=\"#{fmt(w)}\"")
      .sub(/PageHeight="[^"]*"/, "PageHeight=\"#{fmt(h)}\"")
      .sub(/DocumentBleedTopOffset="[^"]*"/, "DocumentBleedTopOffset=\"#{fmt(bleed)}\"")
      .sub(/DocumentBleedBottomOffset="[^"]*"/, "DocumentBleedBottomOffset=\"#{fmt(bleed)}\"")
      .sub(/DocumentBleedInsideOrLeftOffset="[^"]*"/, "DocumentBleedInsideOrLeftOffset=\"#{fmt(bleed)}\"")
      .sub(/DocumentBleedOutsideOrRightOffset="[^"]*"/, "DocumentBleedOutsideOrRightOffset=\"#{fmt(bleed)}\"")
      .sub(/DocumentBleedUniformSize="[^"]*"/, "DocumentBleedUniformSize=\"true\"")
      .sub(/PagesPerDocument="[^"]*"/, "PagesPerDocument=\"1\"")
      .sub(/FacingPages="[^"]*"/, "FacingPages=\"false\"")
  end

  # Nuance de gris (CMYK 0/0/0/70) pour le renforcement de reliure — absente du gabarit
  # vendu (seuls Black/Paper/CMY/quelques teintes vives y sont définis).
  def self.add_binding_swatch(graphic_xml)
    swatch = %(\t<Color Self="#{BINDING_COLOR}" Model="Process" Space="CMYK" ColorValue="0 0 0 70" ColorOverride="Normal" AlternateSpace="NoAlternateColor" AlternateColorValue="" Name="Gris reliure" ColorEditable="true" ColorRemovable="true" Visible="true" />\n)
    graphic_xml.sub("</idPkg:Graphic>", "#{swatch}</idPkg:Graphic>")
  end

  def self.binding_frame(ids, spine_x0, spine_x1, h, overlap)
    { kind: :binding, self: ids.next!, x: spine_x0 - overlap, y: 0.0,
      w: (spine_x1 + overlap) - (spine_x0 - overlap), h: h }
  end

  # Cadre en pointillés marquant le dos (bord à bord, bleed inclus) — repère toujours
  # visible même quand les cadres de texte remplissent tout .
  def self.spine_outline_frame(ids, spine_x0, spine_x1, h)
    { kind: :spine_outline, self: ids.next!, x: spine_x0, y: 0.0, w: spine_x1 - spine_x0, h: h }
  end

  # Axe Y IDML : 0 = HAUT de page, croissant VERS LE BAS (confirmé sur un fichier Adobe
  # réel, `GeometricBounds`/`ItemTransform` — sens inverse de ce que le code précédent
  # supposait, bug réel : tout s'empilait près du bas, jamais vers le haut, 2026-08-22).
  # `top_bound` (petit, vrai haut) / `bottom_bound` (grand, vrai bas).
  def self.place_fields(ids, fields, conf, entries, carnet_folder, x0, x1, top_bound, bottom_bound)
    present = fields.filter_map do |field|
      value = field.resolver.call(conf, entries)
      [field, value] if value && !value.to_s.strip.empty?
    end

    w = x1 - x0
    text_w = w * TEXT_WIDTH_SCALE
    # Les champs "contours" (titre/sous-titre/auteur) partagent UNE SEULE échelle de
    # réduction — sinon chacun rétrécit indépendamment selon SA propre largeur et
    # l'ordre des tailles peut s'inverser (sous-titre plus gros que le titre, bug réel
    # constaté 2026-08-22, le titre étant plus long donc réduit plus fort tout seul).
    outline_fit = present.filter_map { |field, value| outline_dims(field, value, text_w)[:fit] if OUTLINE_FIELDS.include?(field.name) }.min || 1.0
    heights = present.map { |field, value|
      next nominal_height(field, value, w) if field.kind == :image
      next outline_dims(field, value, text_w)[:natural_h] * outline_fit if OUTLINE_FIELDS.include?(field.name)

      nominal_height(field, value, text_w)
    }
    available = bottom_bound - top_bound
    needed = heights.sum + FRAME_GAP * [present.size - 1, 0].max
    scale = (needed.positive? && needed > available) ? available / needed : 1.0

    frames = []
    stories = []
    stack_h = heights.sum { |h| h * scale } + FRAME_GAP * scale * [present.size - 1, 0].max
    y = top_bound + (available - stack_h) / 2.0

    present.each_with_index do |(field, value), i|
      frame_h = heights[i] * scale
      frame_self = ids.next!
      if field.kind == :image
        path = File.expand_path(value, carnet_folder)
        frame_w = image_frame_width(path, w, frame_h)
        fx = x0 + (w - frame_w) / 2.0
        frames << { kind: :image, self: frame_self, name: field.name, x: fx, y: y, w: frame_w, h: frame_h, image_path: path }
      elsif OUTLINE_FIELDS.include?(field.name)
        dims = outline_dims(field, value, text_w)
        total_scale = outline_fit * scale
        w_final = dims[:natural_w] * total_scale
        fx = x0 + (w - w_final) / 2.0
        frames << { kind: :outline_text, self: frame_self, name: field.name, x: fx, y: y, text: value.to_s,
                    size: dims[:size], transform_scale: total_scale }
      else
        story_self = ids.next!
        stories << { self: story_self, content: value.to_s, font_size: FONT_SIZE.fetch(field.name, 12.0) }
        fx = x0 + (w - text_w) / 2.0
        frames << { kind: :text, self: frame_self, name: field.name, x: fx, y: y, w: text_w, h: frame_h, story_self: story_self }
      end
      y += frame_h + FRAME_GAP * scale
    end

    { frames: frames, stories: stories }
  end

  # Largeur du cadre image dérivée de l'aspect réel à la hauteur cible — jamais la
  # largeur pleine colonne (cadre énorme avec l'image perdue dans un coin, bug constaté
  # 2026-08-22), plafonnée à la largeur disponible.
  def self.image_frame_width(path, max_w, h)
    w0, h0 = image_wh(path)
    [h * (w0 / h0.to_f), max_w].min
  end

  def self.nominal_height(field, value, w)
    return field.name == "cover_image" ? COVER_IMAGE_FRAME_H : LOGO_FRAME_H if field.kind == :image
    return outline_dims(field, value, w)[:h] if OUTLINE_FIELDS.include?(field.name)

    size = FONT_SIZE.fetch(field.name, 12.0)
    line_h = size * 1.2
    chars_per_line = [(w / (size * CHAR_WIDTH_FACTOR)).floor, 1].max
    lines = value.to_s.split("\n")
    total_lines = lines.sum { |l| [(l.length / chars_per_line.to_f).ceil, 1].max }
    [total_lines * line_h, TEXT_FRAME_H].max
  end

  # Dimensions naturelles (police nominale `FONT_SIZE`) + échelle nécessaire pour tenir
  # dans `max_w` — même formule en mesure (`nominal_height`) et en dessin, jamais deux
  # calculs susceptibles de diverger.
  def self.outline_dims(field, value, max_w)
    size = FONT_SIZE.fetch(field.name, 24.0)
    l = TextOutliner.layout(value.to_s, OUTLINE_FONT, size)
    fit = l[:width].positive? ? [max_w / l[:width], 1.0].min : 1.0
    { w: l[:width] * fit, h: l[:height] * fit, natural_w: l[:width], natural_h: l[:height], fit: fit, size: size }
  end

  def self.spread_xml(page, w, h)
    frames_xml = page[:frames].map do |f|
      case f[:kind]
      when :image then image_frame_xml(f)
      when :binding then binding_rectangle_xml(f)
      when :spine_outline then spine_outline_xml(f)
      when :outline_text then outline_text_xml(f)
      else text_frame_xml(f)
      end
    end.join("\n")
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <idPkg:Spread xmlns:idPkg="http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging" DOMVersion="#{DOM_VERSION}">
      \t<Spread Self="#{page[:self]}" FlattenerOverride="Default" AllowPageShuffle="true" ItemTransform="1 0 0 1 0 0" ShowMasterItems="false" PageCount="1" BindingLocation="0" PageTransitionType="None" PageTransitionDirection="NotApplicable" PageTransitionDuration="Medium">
      \t\t<Page Self="#{page[:self]}p" AppliedMaster="n" OverrideList="" Name="Couverture" GeometricBounds="0 0 #{fmt(h)} #{fmt(w)}" ItemTransform="1 0 0 1 0 0" LayoutRule="Off" SnapshotBlendingMode="IgnoreLayoutSnapshots" OptionalPage="false" GridStartingPoint="TopOutside" UseMasterGrid="false" TabOrder="">
      \t\t\t<MarginPreference ColumnCount="1" ColumnGutter="12" Top="0" Bottom="0" Left="0" Right="0" ColumnDirection="Horizontal" />
      \t\t</Page>
      #{frames_xml}
      \t</Spread>
      </idPkg:Spread>
    XML
  end

  def self.rect_path_xml(w, h)
    <<~XML.chomp
      \t\t\t<Properties>
      \t\t\t\t<PathGeometry>
      \t\t\t\t\t<GeometryPathType PathOpen="false">
      \t\t\t\t\t\t<PathPointArray>
      \t\t\t\t\t\t\t<PathPointType Anchor="0 0" LeftDirection="0 0" RightDirection="0 0" />
      \t\t\t\t\t\t\t<PathPointType Anchor="0 #{fmt(h)}" LeftDirection="0 #{fmt(h)}" RightDirection="0 #{fmt(h)}" />
      \t\t\t\t\t\t\t<PathPointType Anchor="#{fmt(w)} #{fmt(h)}" LeftDirection="#{fmt(w)} #{fmt(h)}" RightDirection="#{fmt(w)} #{fmt(h)}" />
      \t\t\t\t\t\t\t<PathPointType Anchor="#{fmt(w)} 0" LeftDirection="#{fmt(w)} 0" RightDirection="#{fmt(w)} 0" />
      \t\t\t\t\t\t</PathPointArray>
      \t\t\t\t\t</GeometryPathType>
      \t\t\t\t</PathGeometry>
      \t\t\t</Properties>
    XML
  end

  def self.text_frame_xml(f)
    <<~XML.chomp
      \t\t<TextFrame Self="#{f[:self]}" Name="#{f[:name]}" ItemLayer="uba" ParentStory="#{f[:story_self]}" PreviousTextFrame="n" NextTextFrame="n" ContentType="TextType" ItemTransform="1 0 0 1 #{fmt(f[:x])} #{fmt(f[:y])}">
      #{rect_path_xml(f[:w], f[:h])}
      \t\t\t<TextFramePreference TextColumnCount="1" TextColumnFixedWidth="#{fmt(f[:w])}" />
      \t\t</TextFrame>
    XML
  end

  def self.outline_text_xml(f)
    ts = f[:transform_scale]
    transform = "#{fmt(ts)} 0 0 #{fmt(ts)} #{fmt(f[:x])} #{fmt(f[:y])}"
    xml, = TextOutliner.polygon_xml(f[:self], f[:text], OUTLINE_FONT, f[:size], transform: transform)
    xml
  end

  # Deux différences trouvées avec un vrai fichier Adobe (`sample-with-image.idml`),
  # 2026-08-22, après plusieurs essais où l'image restait invisible malgré une géométrie
  # correcte : (1) `LinkResourceURI` Adobe utilise UN SEUL slash après "file:"
  # (`file:/Users/...`), pas `file://` standard ; (2) `ItemLayer` absent de mes cadres,
  # présent sur tous les items réels.
  LINK_FORMAT = { ".png" => "$ID/PNG", ".jpg" => "$ID/JPEG", ".jpeg" => "$ID/JPEG", ".svg" => "$ID/SVG" }.freeze

  def self.image_frame_xml(f)
    w0, h0 = image_wh(f[:image_path])
    scale = [f[:w] / w0, f[:h] / h0].min
    uri = f[:link_uri]
    ext = File.extname(f[:image_path]).downcase
    format = LINK_FORMAT.fetch(ext, "$ID/")
    # `ActualPpi`/`EffectivePpi` — absents (encore un écart avec le fichier Adobe réel) :
    # "taille minimale" à régler pour voir l'image, une fois le lien
    # résolu (2026-08-22) — calculés depuis la taille réelle affichée, pas une valeur en dur.
    actual_ppi = 72
    effective_ppi_w = (w0 * 72.0 / f[:w]).round
    effective_ppi_h = (h0 * 72.0 / f[:h]).round
    <<~XML.chomp
      \t\t<Rectangle Self="#{f[:self]}" Name="#{f[:name]}" ItemLayer="uba" ContentType="GraphicType" ItemTransform="1 0 0 1 #{fmt(f[:x])} #{fmt(f[:y])}">
      #{rect_path_xml(f[:w], f[:h])}
      \t\t\t<FrameFittingOption AutoFit="false" FittingOnEmptyFrame="Proportionally" FittingAlignment="TopLeftAnchor" />
      \t\t\t<Image Self="#{f[:self]}img" Space="$ID/#Links_RGB" ActualPpi="#{actual_ppi} #{actual_ppi}" EffectivePpi="#{effective_ppi_w} #{effective_ppi_h}" ItemTransform="#{fmt(scale)} 0 0 #{fmt(scale)} #{fmt(f[:x])} #{fmt(f[:y])}">
      \t\t\t\t<Properties>
      \t\t\t\t\t<GraphicBounds Left="0" Top="0" Right="#{fmt(w0)}" Bottom="#{fmt(h0)}" />
      \t\t\t\t</Properties>
      \t\t\t\t<Link Self="#{f[:self]}link" LinkResourceURI="#{uri}" LinkResourceFormat="#{format}" StoredState="Normal" LinkClassID="35906" LinkClientID="257" ShowInUI="true" CanEmbed="true" CanUnembed="true" CanPackage="true" ImportPolicy="NoAutoImport" ExportPolicy="NoAutoExport" />
      \t\t\t</Image>
      \t\t</Rectangle>
    XML
  end

  # Rectangle plein gris foncé, VERROUILLÉ — renforcement de reliure. `FillColor`
  # référence une couleur définie dans `Resources/Graphic.xml` du gabarit vendu
  # (non modifié ici) : à défaut de résolution, Affinity retombe sur le noir/gris par
  # défaut plutôt que d'échouer — acceptable pour un premier essai.
  def self.binding_rectangle_xml(f)
    <<~XML.chomp
      \t\t<Rectangle Self="#{f[:self]}" Name="binding" ItemLayer="uba" ContentType="Unassigned" Locked="true" FillColor="#{BINDING_COLOR}" ItemTransform="1 0 0 1 #{fmt(f[:x])} #{fmt(f[:y])}">
      #{rect_path_xml(f[:w], f[:h])}
      \t\t</Rectangle>
    XML
  end

  # Cadre en pointillés (dos), NON verrouillé — repère visuel seulement, pas de fond.
  def self.spine_outline_xml(f)
    <<~XML.chomp
      \t\t<Rectangle Self="#{f[:self]}" Name="dos" ItemLayer="uba" ContentType="Unassigned" FillColor="Color/None" StrokeColor="Color/Black" StrokeWeight="1" StrokeStyle="StrokeStyle/$ID/Dashed" ItemTransform="1 0 0 1 #{fmt(f[:x])} #{fmt(f[:y])}">
      #{rect_path_xml(f[:w], f[:h])}
      \t\t</Rectangle>
    XML
  end

  def self.story_xml(story)
    size = story[:font_size] || 12.0
    lines = story[:content].to_s.split("\n").map { |l| l.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;") }
    # Retours chariot têtus (liste chansons, plusieurs essais) : au lieu
    # d'un `ParagraphStyleRange` par ligne (pourtant le motif Adobe standard, vérifié sur
    # un fichier réel), UN SEUL paragraphe avec `<Content>`/`<Br/>` alternés — 2e motif
    # réel Adobe rencontré (interview.idml, retours à l'intérieur d'un même paragraphe).
    runs = lines.map { |l| "\t\t\t\t<Content>#{l}</Content>" }.join("\n\t\t\t\t<Br />\n")
    paragraphs = <<~PARA.chomp
      \t\t<ParagraphStyleRange AppliedParagraphStyle="ParagraphStyle/$ID/NormalParagraphStyle" Justification="CenterAlign">
      \t\t\t<CharacterStyleRange AppliedCharacterStyle="CharacterStyle/$ID/[No character style]" PointSize="#{fmt(size)}">
      #{runs}
      \t\t\t</CharacterStyleRange>
      \t\t</ParagraphStyleRange>
    PARA

    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <idPkg:Story xmlns:idPkg="http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging" DOMVersion="#{DOM_VERSION}">
      \t<Story Self="#{story[:self]}" AppliedTOCStyle="n" UserText="true" IsAnEndnoteStory="false" TrackChanges="false" StoryTitle="$ID/" AppliedNamedGrid="n">
      #{paragraphs}
      \t</Story>
      </idPkg:Story>
    XML
  end

  def self.designmap_xml(story_ids, pages)
    story_pkg_refs = story_ids.map { |sid| "\t<idPkg:Story src=\"Stories/Story_#{sid}.xml\" />" }.join("\n")
    spread_pkg_refs = pages.map { |p| "\t<idPkg:Spread src=\"Spreads/Spread_#{p[:self]}.xml\" />" }.join("\n")
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Document xmlns:idPkg="http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging" DOMVersion="#{DOM_VERSION}" Self="d" StoryList="#{story_ids.join(" ")}" ZeroPoint="0 0">
      \t<idPkg:Graphic src="Resources/Graphic.xml" />
      \t<idPkg:Fonts src="Resources/Fonts.xml" />
      \t<idPkg:Styles src="Resources/Styles.xml" />
      \t<idPkg:Preferences src="Resources/Preferences.xml" />
      \t<idPkg:Tags src="XML/Tags.xml" />
      \t<Layer Self="uba" Name="Layer 1" Visible="true" Locked="false" />
      #{spread_pkg_refs}
      \t<idPkg:BackingStory src="XML/BackingStory.xml" />
      #{story_pkg_refs}
      </Document>
    XML
  end

  def self.fmt(n)
    n.round(4).to_s.sub(/\.0\z/, "")
  end

  def self.image_wh(path)
    if path.downcase.end_with?(".svg")
      content = File.read(path)
      m = content.match(/viewBox\s*=\s*"[\d.\-]+\s+[\d.\-]+\s+([\d.]+)\s+([\d.]+)"/)
      m ? [m[1].to_f, m[2].to_f] : [1.0, 1.0]
    else
      out = `magick identify -format "%w %h" #{path.shellescape}`
      w, h = out.split.map(&:to_f)
      [w.positive? ? w : 1.0, h.positive? ? h : 1.0]
    end
  end
end
