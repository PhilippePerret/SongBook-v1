require "ttfunk"
require_relative "glyph_outline"

# Texte converti en contours vectoriels (Phil, 2026-08-22 : reproduire "Créer les
# contours" d'InDesign — cadre qui s'étire comme un dessin, pas un cadre de texte
# normal). Utilise `GlyphOutline` (parseur `glyf` TrueType, accents composites gérés).
module TextOutliner
  FONT_CACHE = {}

  def self.font(path)
    FONT_CACHE[path] ||= TTFunk::File.open(path)
  end

  # -> { contours: [ [{x:,y:}, ...], ... ] en points PDF, page IDML (Y croissant vers
  # le bas, origine = coin haut-gauche du texte), width:, height: }
  def self.layout(text, font_path, size_pt)
    file = font(font_path)
    upm = GlyphOutline.units_per_em(file)
    scale = size_pt / upm.to_f
    cmap = file.cmap.unicode.first.code_map
    ascent = file.horizontal_header.ascent * scale
    descent = file.horizontal_header.descent.abs * scale

    x = 0.0
    contours = []
    text.each_char do |ch|
      gid = cmap[ch.ord]
      if !gid || gid.zero?
        x += size_pt * 0.32 # espace/glyphe absent : avance approximative
        next
      end

      glyph = file.find_glyph(gid)
      # `find_glyph` -> nil pour un glyphe sans contour (espace notamment) : AUCUN
      # dessin, mais l'avance (espacement horizontal) doit quand même compter — bug
      # réel trouvé ici (espaces disparues entre les mots, 2026-08-22) : l'ancien code
      # sautait aussi l'avance avec `next`, pas seulement le dessin.
      if glyph
        GlyphOutline.contours(glyph, file).each do |c|
          anchors = GlyphOutline.to_cubic_anchors(c)
          next if anchors.empty?

          contours << anchors.map { |a|
            {
              anchor: { x: (a[:anchor].x * scale) + x, y: ascent - (a[:anchor].y * scale) },
              left: { x: (a[:left][:x] * scale) + x, y: ascent - (a[:left][:y] * scale) },
              right: { x: (a[:right][:x] * scale) + x, y: ascent - (a[:right][:y] * scale) },
            }
          }
        end
      end
      x += file.horizontal_metrics.for(gid).advance_width * scale
    end

    { contours: contours, width: x, height: ascent + descent }
  end

  # Géométrie LOCALE (0,0 = coin haut-gauche du texte) — le positionnement/l'échelle
  # finale passent par `ItemTransform` sur le `<Polygon>`, pas ici (permet à l'appelant
  # de réduire le texte pour tenir dans sa colonne sans recalculer les contours).
  def self.polygon_xml(self_id, text, font_path, size_pt, transform:)
    l = layout(text, font_path, size_pt)
    geometries = l[:contours].map { |contour|
      points_xml = contour.map { |p|
        %(<PathPointType Anchor="#{fmt(p[:anchor][:x])} #{fmt(p[:anchor][:y])}" LeftDirection="#{fmt(p[:left][:x])} #{fmt(p[:left][:y])}" RightDirection="#{fmt(p[:right][:x])} #{fmt(p[:right][:y])}" />)
      }.join("\n\t\t\t\t\t\t\t")
      <<~GEO.chomp
        \t\t\t\t\t<GeometryPathType PathOpen="false">
        \t\t\t\t\t\t<PathPointArray>
        \t\t\t\t\t\t\t#{points_xml}
        \t\t\t\t\t\t</PathPointArray>
        \t\t\t\t\t</GeometryPathType>
      GEO
    }.join("\n")

    xml = <<~XML.chomp
      \t\t<Polygon Self="#{self_id}" Name="#{text[0, 20]}" ItemLayer="uba" ContentType="Unassigned" FillColor="Color/Black" StrokeColor="Color/None" ItemTransform="#{transform}">
      \t\t\t<Properties>
      \t\t\t\t<PathGeometry>
      #{geometries}
      \t\t\t\t</PathGeometry>
      \t\t\t</Properties>
      \t\t</Polygon>
    XML
    [xml, l[:width], l[:height]]
  end

  def self.fmt(n)
    n.round(4).to_s.sub(/\.0\z/, "")
  end
end
