# Générateur de diagramme d'accord (SVG), manche horizontal — sillet à gauche,
# cordes empilées (corde 1/aiguë en haut, corde 6/grave en bas), frettes croissant
# vers la droite. Style fixé à la main pour Am/C/D/E7/F (voir specs.md, section
# "Diagrammes d'accords") ; toutes les constantes ci-dessous sont RELEVÉES sur ces
# fichiers existants, pas inventées — un accord généré ici doit être visuellement
# identique aux 5 premiers.
#
# Coordonnées recalculées directement (axes échangés), PAS une simple rotation SVG
# globale — sinon le texte (nom, chiffres) tournerait aussi, illisible.
module ChordDiagram
  GW = 51 # écart entre deux cordes
  GH = 75 # largeur d'une case
  VC = 4  # cases visibles
  GRID_H = GW * 5 # 6 cordes = 5 intervalles, hauteur totale de la grille
  GRID_W = GH * VC

  # Y de la corde d'indice i (0=corde6/grave en bas .. 5=corde1/aiguë en haut).
  def self.string_y(i)
    (5 - i) * GW
  end

  # Centre X de la Nème case visible (1..VC).
  def self.fret_x(fret)
    (fret - 1) * GH + GH / 2.0
  end

  # positions : 6 entrées, corde grave (6) → aiguë (1), index 0 = corde 6 .. index 5
  # = corde 1.
  #   :open  -> corde à vide
  #   :muted -> corde étouffée
  #   Integer (1..VC, ou au-delà si position décalée) -> numéro de case
  # fingers : 6 entrées parallèles (nil, "1".."4", ou "p" pour le pouce) — ignoré
  #   pour :open/:muted.
  # barre : optionnel { fret:, finger:, indices: [0..5, ...] } — `indices` = cordes
  #   RÉELLEMENT couvertes par le barré, toujours dessiné borné à ces cordes (petit
  #   ou grand barré).
  # bass : nom de la basse si accord renversé (ex. "F♯"), sinon nil.
  # optionals : 6 entrées parallèles (bool) — note FACULTATIVE (même doigt qu'une
  #   autre corde, qui peut s'étendre là en plus), affichée en gris entre parenthèses.
  def self.build(name:, positions:, fingers:, barre: nil, bass: nil, optionals: Array.new(6, false))
    raise ArgumentError, "positions/fingers doivent avoir 6 entrées" if positions.size != 6 || fingers.size != 6

    fretted_only = positions.grep(Integer)
    base_fret = (fretted_only.any? && fretted_only.max > VC) ? fretted_only.min : 1

    svg = +%(<svg xmlns="http://www.w3.org/2000/svg" viewBox="-60 -115 420 445" font-family="sans-serif">\n)
    svg << name_label(name, bass)
    svg << grid
    show_nut = base_fret == 1
    if base_fret > 1
      svg << position_label(base_fret)
    elsif show_nut
      svg << nut
    end

    barred = barre ? barre[:indices] : []

    positions.each_with_index do |pos, i|
      y = string_y(i)
      next if barred.include?(i)

      case pos
      when :open
        svg << open_circle(y)
      when :muted
        svg << muted_cross(y)
      when Integer
        x = fret_x(pos - base_fret + 1)
        svg << fretted_note(x, y, fingers[i], color: optionals[i] ? "999999" : "000000")
        svg << parentheses(x, y) if optionals[i]
      end
    end

    svg << barre_line(barre[:fret] - base_fret + 1, barre[:finger], barre[:indices]) if barre

    svg << "</svg>\n"
    svg
  end

  # Dièse/bémol collé au nom — séparé en tspan avec un dx négatif pour resserrer
  # l'espacement naturel de la police, trop large sinon.
  def self.name_tspans(name, size:, accidental_dx: -6, leading_dx: nil)
    lead = leading_dx ? %( dx="#{leading_dx}") : ""
    if name =~ /([♯♭])/
      pre, accidental, post = $`, $1, $'
      %(<tspan font-size="#{size}" font-weight="bold"#{lead}>#{pre}</tspan><tspan font-size="#{size}" font-weight="bold" dx="#{accidental_dx}">#{accidental}</tspan><tspan font-size="#{size}" font-weight="bold">#{post}</tspan>)
    else
      %(<tspan font-size="#{size}" font-weight="bold"#{lead}>#{name}</tspan>)
    end
  end

  # Basse : plus petite que le nom mais visible, "/" pas plus éloigné, note détachée
  # du "/", et dièse/bémol détaché de sa note (contraire du nom principal — dx
  # positif, pas négatif). Qualité (ex. "sus", "7") plus petite que la fondamentale.
  def self.split_name(name)
    m = /\A([A-G][♯♭]?)(.*)\z/.match(name)
    m ? [m[1], m[2]] : [name, ""]
  end

  def self.name_label(name, bass)
    root, quality = split_name(name)
    main = name_tspans(root, size: 56)
    main += name_tspans(quality, size: 34, accidental_dx: 2, leading_dx: 2) unless quality.empty?
    if bass
      %(<text x="150" y="-60" dy="0.35em" text-anchor="middle">#{main}<tspan font-size="34" font-weight="bold" dx="6">/</tspan>#{name_tspans(bass, size: 34, accidental_dx: 2, leading_dx: 4)}</text>\n)
    else
      %(<text x="150" y="-60" dy="0.35em" text-anchor="middle">#{main}</text>\n)
    end
  end

  def self.grid
    lines = +""
    6.times { |r| lines << %(<line x1="0" y1="#{r * GW}" x2="#{GRID_W}" y2="#{r * GW}" stroke="black" stroke-width="3"/>\n) }
    (0..VC).each { |c| lines << %(<line x1="#{c * GH}" y1="0" x2="#{c * GH}" y2="#{GRID_H}" stroke="black" stroke-width="3"/>\n) }
    lines
  end

  def self.nut
    %(<line x1="0" y1="-6" x2="0" y2="#{GRID_H + 6}" stroke="black" stroke-width="10"/>\n)
  end

  def self.open_circle(y)
    %(<circle cx="-25" cy="#{y}" r="14" fill="none" stroke="black" stroke-width="3"/>\n)
  end

  def self.muted_cross(y)
    r = 14 * Math.sqrt(0.5)
    cx = -25
    <<~SVG
      <line x1="#{cx - r}" y1="#{y - r}" x2="#{cx + r}" y2="#{y + r}" stroke="black" stroke-width="3"/>
      <line x1="#{cx - r}" y1="#{y + r}" x2="#{cx + r}" y2="#{y - r}" stroke="black" stroke-width="3"/>
    SVG
  end

  DESCENDER_LETTERS = %w[p g j q y].freeze

  def self.finger_label(x, y, finger)
    return "" unless finger

    if DESCENDER_LETTERS.include?(finger.to_s)
      %(<text x="#{x}" y="#{y}" dx="1.7" dy="0.25em" fill="white" font-size="34" font-weight="bold" text-anchor="middle">#{finger}</text>\n)
    else
      %(<text x="#{x}" y="#{y}" dy="0.35em" fill="white" font-size="34" font-weight="bold" text-anchor="middle">#{finger}</text>\n)
    end
  end

  def self.fretted_note(x, y, finger, color: "000000")
    %(<circle cx="#{x}" cy="#{y}" r="22" fill="##{color}"/>\n) + finger_label(x, y, finger)
  end

  # Note facultative (entre parenthèses) affichée moins forte — gris, y compris les
  # parenthèses.
  def self.parentheses(x, y, color: "999999")
    %(<text x="#{x - 30}" y="#{y}" dy="0.35em" font-size="26" font-weight="bold" fill="##{color}" text-anchor="middle">(</text>\n) +
      %(<text x="#{x + 30}" y="#{y}" dy="0.35em" font-size="26" font-weight="bold" fill="##{color}" text-anchor="middle">)</text>\n)
  end

  # Ligne bornée aux cordes RÉELLEMENT couvertes (`indices`) — petit barré (ex. 2
  # cordes) comme grand barré (les 6) rendus correctement, plutôt que toujours
  # pleine largeur.
  def self.barre_line(fret, finger, indices)
    x = fret_x(fret)
    ys = indices.map { |i| string_y(i) }
    y0 = ys.min
    y1 = ys.max
    mid = (y0 + y1) / 2.0
    %(<line x1="#{x}" y1="#{y0}" x2="#{x}" y2="#{y1}" stroke="black" stroke-width="36" stroke-linecap="round"/>\n) +
      finger_label(x, mid, finger)
  end

  # Case de départ : au-dessus de la 1ère case, pour une position décalée (pas de
  # sillet dans ce cas).
  def self.position_label(base_fret)
    %(<text x="#{fret_x(1)}" y="-35" dy="0.35em" font-family="Georgia, serif" text-anchor="middle"><tspan font-size="30" font-weight="bold">#{base_fret}</tspan><tspan font-size="18" font-weight="bold" dy="-0.5em">e</tspan></text>\n)
  end
end
