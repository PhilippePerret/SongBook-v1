require "ttfunk"

# Extraction des contours vectoriels d'un glyphe TrueType (table `glyf`) — pour
# convertir du texte en contours  : reproduire ce qu'InDesign fait
# avec "Créer les contours", nécessaire pour un cadre texte qui s'étire comme un
# dessin). `ttfunk` (déjà présent, dépendance Prawn) ne décode QUE l'en-tête du
# glyphe (bornes, nombre de contours) — jamais les points eux-mêmes (il sert au
# subsetting de police, pas au rendu). Le reste de la table est parsé ici à la main,
# format documenté (Apple/Microsoft TrueType spec, table `glyf`, glyphe simple).
module GlyphOutline
  Point = Struct.new(:x, :y, :on_curve, keyword_init: true)

  def self.units_per_em(ttfunk_file)
    ttfunk_file.header.units_per_em
  end

  # -> [ [Point, Point, ...], ... ] un tableau de contours. Glyphe composé (accents
  # français : é/è/à/ô... — vérifié réel, pas rare) : chaque composant est un glyphe
  # SIMPLE référencé + décalage (x,y) — `ttfunk` ne décode que les ID de composants
  # (utile pour le subsetting), jamais les décalages — reparsés ici.
  ARG_1_AND_2_ARE_WORDS = 0x0001
  ARGS_ARE_XY_VALUES = 0x0002
  WE_HAVE_A_SCALE = 0x0008
  MORE_COMPONENTS = 0x0020
  WE_HAVE_AN_X_AND_Y_SCALE = 0x0040
  WE_HAVE_A_TWO_BY_TWO = 0x0080

  def self.contours(glyph, ttfunk_file = nil)
    return compound_contours(glyph, ttfunk_file) if glyph.compound?

    io = StringIO.new(glyph.raw)
    io.read(10) # number_of_contours, x_min, y_min, x_max, y_max déjà lus par ttfunk
    io.read(glyph.number_of_contours * 2) # end_points_of_contours déjà lus
    instruction_length = io.read(2).unpack1("n")
    io.read(instruction_length)

    n_points = glyph.end_point_of_last_contour
    flags = read_flags(io, n_points)
    xs = read_coords(io, flags, short_bit: 0x02, same_or_positive_bit: 0x10)
    ys = read_coords(io, flags, short_bit: 0x04, same_or_positive_bit: 0x20)

    points = flags.each_with_index.map { |f, i| Point.new(x: xs[i], y: ys[i], on_curve: f & 0x01 != 0) }

    start = 0
    glyph.end_points_of_contours.map do |end_idx|
      contour = points[start..end_idx]
      start = end_idx + 1
      contour
    end
  end

  def self.compound_contours(glyph, ttfunk_file)
    raise "glyphe composé sans accès au fichier (ttfunk_file requis)" unless ttfunk_file

    io = StringIO.new(glyph.raw)
    io.read(10)
    all = []
    loop do
      flags, component_gid = io.read(4).unpack("n2")
      raise "composant sans décalage x/y non géré (point-matching)" if flags & ARGS_ARE_XY_VALUES == 0

      dx, dy = if flags & ARG_1_AND_2_ARE_WORDS != 0
                 io.read(4).unpack("s>2")
               else
                 io.read(2).unpack("c2")
               end

      sx = sy = 1.0
      s01 = s10 = 0.0
      if flags & WE_HAVE_A_SCALE != 0
        sx = sy = io.read(2).unpack1("s>") / 16384.0
      elsif flags & WE_HAVE_AN_X_AND_Y_SCALE != 0
        sx, sy = io.read(4).unpack("s>2").map { |v| v / 16384.0 }
      elsif flags & WE_HAVE_A_TWO_BY_TWO != 0
        sx, s01, s10, sy = io.read(8).unpack("s>4").map { |v| v / 16384.0 }
      end

      component_glyph = ttfunk_file.find_glyph(component_gid)
      component_contours = contours(component_glyph, ttfunk_file)
      component_contours.each do |c|
        all << c.map { |p|
          Point.new(x: (p.x * sx) + (p.y * s10) + dx, y: (p.x * s01) + (p.y * sy) + dy, on_curve: p.on_curve)
        }
      end

      break if flags & MORE_COMPONENTS == 0
    end
    all
  end

  def self.read_flags(io, n_points)
    flags = []
    while flags.size < n_points
      f = io.readbyte
      flags << f
      if f & 0x08 != 0
        repeat = io.readbyte
        repeat.times { flags << f }
      end
    end
    flags
  end

  def self.read_coords(io, flags, short_bit:, same_or_positive_bit:)
    coord = 0
    flags.map do |f|
      if f & short_bit != 0
        delta = io.readbyte
        coord += (f & same_or_positive_bit != 0) ? delta : -delta
      elsif f & same_or_positive_bit == 0
        delta = io.read(2).unpack1("s>")
        coord += delta
      end
      coord
    end
  end

  # Contour TrueType (quadratique, points on/off-curve alternés, point on-curve
  # implicite au milieu de 2 points off-curve consécutifs) -> liste de segments
  # cubiques [ [ancre, poignée_sortante, poignée_entrante, ancre_suivante], ... ],
  # format InDesign/IDML (poignées = coordonnées ABSOLUES, pas des deltas).
  def self.to_cubic_anchors(contour)
    return [] if contour.empty?

    pts = expand_implicit_on_curve(contour)
    on_curve_indices = pts.each_index.select { |i| pts[i].on_curve }
    return [] if on_curve_indices.empty?

    anchors = []
    on_curve_indices.each_with_index do |idx, i|
      next_on_idx = on_curve_indices[(i + 1) % on_curve_indices.size]
      seg = segment_between(pts, idx, next_on_idx)
      anchors << { anchor: pts[idx], right: seg[:c1], left_for_next: seg[:c2] }
    end

    # `left` de chaque ancre = poignée entrante calculée pour l'ancre PRÉCÉDENTE.
    anchors.each_with_index.map do |a, i|
      prev = anchors[(i - 1) % anchors.size]
      { anchor: a[:anchor], left: prev[:left_for_next], right: a[:right] }
    end
  end

  def self.expand_implicit_on_curve(contour)
    out = []
    contour.each_with_index do |p, i|
      out << p
      nxt = contour[(i + 1) % contour.size]
      next unless !p.on_curve && !nxt.on_curve

      out << Point.new(x: (p.x + nxt.x) / 2.0, y: (p.y + nxt.y) / 2.0, on_curve: true)
    end
    out
  end

  # De `pts[i]` (on-curve) à `pts[j]` (on-curve suivant), avec éventuellement UN point
  # de contrôle quadratique entre les deux (jamais plus, grâce à `expand_implicit_on_curve`).
  def self.segment_between(pts, i, j)
    n = pts.size
    between = []
    k = (i + 1) % n
    while k != j
      between << pts[k]
      k = (k + 1) % n
    end
    p0 = pts[i]
    p1 = pts[j]
    if between.empty?
      { c1: { x: p0.x, y: p0.y }, c2: { x: p1.x, y: p1.y } } # segment droit
    else
      c = between.first # point de contrôle quadratique unique
      { c1: { x: p0.x + (2.0 / 3) * (c.x - p0.x), y: p0.y + (2.0 / 3) * (c.y - p0.y) },
        c2: { x: p1.x + (2.0 / 3) * (c.x - p1.x), y: p1.y + (2.0 / 3) * (c.y - p1.y) } }
    end
  end
end
