require_relative "dsl_parser"
require_relative "layout"
require_relative "chord_diagrams"
require_relative "transpose"
require_relative "kdp"
require_relative "locale"
require_relative "file_finder"

# Construit les pages PDF d'UNE chanson — point d'entrée réutilisable (API : "je veux
# juste cette chanson"), orchestrant `DSLParser`/le format `.lyr`+`.gab`+`.infos`,
# `ChordDiagrams` (résolution des diagrammes) et `Layout` (mise en page/dessin).
module PageBuilder
  TABLATOR_PATH = File.expand_path("../tools/tablator/tablator.rb", __dir__)

  # Clés canoniques (anglais) attendues par le gabarit : title/year/lyrics/composer/performer.
  # Table des alias construite en INVERSANT `Loc.get` sur ces clés (Phil, 2026-08-20) :
  # `TABLE[Loc.get(canon)] = canon`. Mémoïsée une fois (`Loc` lui-même ne charge qu'une
  # langue, celle de l'utilisateur — voir `lib/locale.rb`).
  INFOS_CANONICAL_KEYS = %w[title performer composer lyrics year transpose].freeze

  def self.infos_key_aliases
    @infos_key_aliases ||= INFOS_CANONICAL_KEYS.each_with_object({}) do |canon, table|
      term = Loc.get(canon)
      table[term] = canon if term != canon
    end
  end

  # `.infos` : métadonnées, une par ligne "clé: valeur" (pas de YAML/---). Clés alternatives
  # tolérées (Phil, 2026-08-17 : "tu les prends comme possibles dans le code" — pas de
  # réécriture de fichier imposée) : n'écrasent JAMAIS la clé canonique si elle est déjà
  # présente.
  def self.parse_infos(path)
    meta = {}
    File.foreach(path) do |line|
      k, v = line.strip.split(":", 2)
      meta[k.strip] = v.strip if k && v && !k.strip.empty?
    end
    infos_key_aliases.each { |alt, canon| meta[canon] ||= meta[alt] }
    meta
  end

  # `.lyr` : couplets — chaque paragraphe commence par `{nom}` (SANS ":", à ne pas confondre
  # avec une directive `{clé: valeur}`), suivi des lignes accord/texte. Le nom est OPTIONNEL
  # (règle : rien ne doit être impossible, Phil 2026-08-17) — un paragraphe sans `{nom}` reçoit
  # `couplet-N` (N = position du paragraphe dans le fichier).
  # `{nom}` répété SANS corps : rappel — reprend à cette position le contenu déjà défini
  # sous ce nom (ex. refrain qui revient plusieurs fois dans la chanson). Répété AVEC corps :
  # redéfinition, remplace le contenu précédent (signalé en conflict log, à l'user de juger).
  # Renvoie [Hash{nom => Block}, Array<nom>] — le Hash pour être pioché par nom depuis le
  # `.gab` (`{song: nom}`), l'Array pour l'ordre réel d'apparition (avec répétitions) utilisé
  # par `default_items`.
  # Reconnaît un paragraphe comme réapparition d'un bloc déjà vu quand son CONTENU est
  # identique à un bloc déjà stocké — que ce soit via `{nom}` répété (avec ou sans corps)
  # ou un paragraphe sans nom recopiant mot pour mot un couplet/refrain déjà défini (ex.
  # AYNL, dernier refrain recopié en entier sans `{refrain}`). Sans ça, le paragraphe
  # récupère le mauvais "type" (`couplet-N` auto), ce qui casse le pairage par type (RAO5).
  # Deux paragraphes de MÊME NOM mais de contenu DIFFÉRENT restent une vraie redéfinition :
  # au lieu d'écraser (perte de contenu, interdit — Phil 2026-08-18), le 2nd est renommé en
  # suffixe (`nom-2`, `nom-3`...) pour que les deux soient rendus.
  def self.parse_lyr(path)
    blocks = {}
    order = []
    raw_bodies = {}
    paragraphs = File.read(path).split(/\n{2,}/).map(&:strip).reject(&:empty?)
    paragraphs.each_with_index do |para, i|
      lines = para.split("\n")
      header = lines.first
      if header =~ /\A\{([^:;}]+)\}\z/
        given_name = Regexp.last_match(1).strip
        body = lines[1..] || []
      else
        given_name = nil
        body = lines
      end

      key = body.join("\n")
      existing_name = body.empty? ? nil : raw_bodies[key]

      if existing_name
        name = existing_name
        # Contenu identique à un bloc déjà stocké (ex. refrain repris mot pour mot sous un
        # {nom} DIFFÉRENT, "refrain-2" reprenant "refrain-1") : `order`/le pairage auto
        # continuent de voir le nom canonique (`existing_name`, comportement documenté
        # ci-dessus, inchangé) — mais le nom littéral écrit dans le fichier (`given_name`)
        # doit RESTER résolvable tel quel pour un `.gab` qui le référence explicitement par
        # son propre nom (bug constaté 2026-08-21, "All You Need Is Love" : `{refrain-2}`
        # existe bien dans le `.lyr`, mais un `.gab` qui l'appelle plantait tout le carnet
        # — `Hash#fetch` ne trouvait jamais "refrain-2", silencieusement absorbé par
        # "refrain-1"). Alias, pas une 2e copie : même objet `Block`.
        if given_name && given_name != name && !blocks.key?(given_name)
          blocks[given_name] = blocks[name]
          Layout.log_build("bloc \"#{given_name}\" (contenu identique à \"#{name}\") : alias résolvable vers le même contenu")
        end
      elsif given_name && blocks.key?(given_name) && !body.empty?
        original = given_name
        n = 2
        n += 1 while blocks.key?("#{original}-#{n}")
        name = "#{original}-#{n}"
        Layout.conflict!("bloc \"#{original}\" redéfini", solution: "renommé en \"#{name}\" pour conserver les deux contenus")
      else
        name = given_name || "couplet-#{i + 1}"
      end

      order << name
      next if blocks.key?(name) # contenu déjà stocké (répétition par nom ou par contenu)

      raw_bodies[key] = name
      blocks[name] = Block.new(lines: body.map { |l| Line.new(segments: DSLParser.parse_line(l)) }, directives: {}, paired_with_previous: false)
    end
    [blocks, order]
  end

  GabItem = Struct.new(:type, :data)

  # `.gab` : suite de paragraphes — soit une directive `{clé: valeur; ...}` (classée par la
  # clé qu'elle porte : titre/tabla/diags), soit une row de contenu `{song: nom}` (une ou
  # deux, séparées par `//` pour le côte-à-côte, comme le `//` du DSL simple), soit une row
  # de blocs `.lyr` référencés DIRECTEMENT par leur nom `{nom}` (sans `song:`) — `+` entre
  # deux `{nom}` CONCATÈNE leurs paroles en un seul bloc rendu (Phil, 2026-08-19 : forcer
  # un pseudo-refrain coupé en plusieurs blocs à s'afficher comme un seul, à côté d'un
  # couplet, via `//`). Ex. `{couplet-1} // {refrain-part1-1} + {refrain-part2-1}`.
  ROW_TOKEN_RE = /\A\{[^:;}]+\}(\s*\+\s*\{[^:;}]+\})*\z/.freeze

  # Une ligne = un paragraphe (contrairement au `.lyr`, où une strophe peut s'étaler sur
  # plusieurs lignes et a donc besoin d'une ligne vide pour savoir où elle s'arrête — un
  # paragraphe `.gab` tient TOUJOURS sur une seule ligne, `{nom}`/`{song: nom}`/directive,
  # jamais ambigu : exiger une ligne vide entre chaque n'avait pas de sens ici, imposé sans
  # concertation par une session précédente — retiré, Phil 2026-08-21). Lignes vides
  # tolérées (ignorées), ni obligatoires ni interdites.
  def self.parse_gab(path)
    File.read(path).split("\n").map(&:strip).reject(&:empty?).map do |para|
      if para.include?("{song:")
        names = para.split("//").filter_map { |chunk| chunk[/\{song:\s*([^;}]+)/, 1]&.strip }
        GabItem.new(:row, names)
      elsif (cols = para.split("//").map(&:strip)).all? { |c| c =~ ROW_TOKEN_RE }
        names = cols.map { |c| c.scan(/\{([^:;}]+)\}/).flatten.map(&:strip).join("+") }
        GabItem.new(:row, names)
      else
        inner = para[/\A\{(.*)\}\z/m, 1] || ""
        dirs = {}
        inner.split(";").each do |pair|
          k, v = pair.split(":", 2)
          next unless k && v && !k.strip.empty?

          dirs[k.strip.to_sym] = v.strip.gsub(/\A["']|["']\z/, "")
        end
        # `tabla`/`diags` avant `title` : la directive tabla porte elle-même une clé
        # `title` (sa légende) — sinon elle se ferait passer pour la config d'en-tête.
        type = %i[tabla diags title].find { |k| dirs.key?(k) } || :unknown
        GabItem.new(type, dirs)
      end
    end
  end

  # Génère le SVG de la tabla à la demande si absent, ou si le `.tab` source est plus
  # récent que le `.svg` déjà là (cache invalidé par date de fichier). `name` sans
  # extension. Renvoie le chemin du SVG, ou nil si ni SVG ni .tab n'existent.
  def self.ensure_tabla_svg(folder, name)
    svg_path = File.join(folder, "#{name}.svg")
    tab_path = File.join(folder, "#{name}.tab")
    return svg_path if File.exist?(svg_path) && (!File.exist?(tab_path) || File.mtime(tab_path) <= File.mtime(svg_path))
    return nil unless File.exist?(tab_path)

    system("ruby", TABLATOR_PATH, tab_path, "-o", File.join(folder, name), out: File::NULL, err: File::NULL) or
      raise "échec de tablator sur #{tab_path}"
    svg_path
  end

  # Valeurs par défaut (Phil, 2026-08-17 : "le moins de définitions possibles" — un `.gab`
  # ne sert qu'à ÉCARTER ces défauts, jamais à les répéter). PLUS TARD : fichier YAML de
  # config SongBook, pour qui veut les changer sans toucher au code.
  DEFAULT_TITLE_BAND = true
  DEFAULT_DIAG_POSITION = "left" # = "intérieur"

  # `.gab` absent : couplets du `.lyr` pairés côte à côte 2 par 2, dans leur ordre
  # d'apparition RÉEL (`order`, répétitions incluses — un refrain qui revient 3 fois dans
  # la chanson est réimprimé 3 fois), jamais l'affichage "empilé" façon ChordPro, avec les
  # défauts ci-dessus.
  # Bloc sans corps (`{nom}` sans ligne dessous — voir `parse_lyr`) EXCLU du pairage : sinon
  # il gaspille toute une colonne de la row où il tombe (bug trouvé, 2026-08-18, sur "Au fur
  # et à mesure" — 2 rows sur 3 pages n'affichaient qu'un seul couplet, l'autre colonne vide).
  def self.block_kind(name)
    name.sub(/-\d+\z/, "")
  end

  # `title_band`/`diag_position` : défauts de CE dossier (Manuel/song/layout.adoc, voir
  # `title_band`/`diag_position` par défaut, remplacés par le `layout:` du carnet quand
  # il est fourni — voir `build`). `lyrics_flux: :side` (défaut, "côte à côte") pair les
  # blocs 2 par 2 comme avant ; `:vertical` ("l'une en dessous de l'autre", layouts Column/
  # Column-B) ne pair jamais, chaque bloc a sa propre row. `:free` pas encore implémenté.
  def self.default_items(lyr_blocks, order, title_band: DEFAULT_TITLE_BAND, diag_position: DEFAULT_DIAG_POSITION, lyrics_flux: :side)
    items = [GabItem.new(:title, { title: title_band ? "band" : "inline" }), GabItem.new(:diags, { position: diag_position })]
    names = order.reject { |name| lyr_blocks.fetch(name).lines.empty? }

    raise "lyrics_flux :free (Manuel/song/layout.adoc) pas encore implémenté" if lyrics_flux == :free

    if lyrics_flux == :vertical
      Layout.log_build("lyrics_flux=:vertical : #{names.size} bloc(s), chacun sa propre row")
      names.each { |name| items << GabItem.new(:row, [name]) }
      return items
    end

    pending = nil
    names.each do |name|
      if pending && block_kind(pending) == block_kind(name)
        Layout.log_build("blocs \"#{pending}\"+\"#{name}\" pairés côte à côte (RAO5, même type \"#{block_kind(name)}\")")
        items << GabItem.new(:row, [pending, name])
        pending = nil
      else
        items << GabItem.new(:row, [pending]) if pending
        pending = name
      end
    end
    items << GabItem.new(:row, [pending]) if pending
    items
  end

  # Bloc `.gab` référencé introuvable TEL QUEL dans le `.lyr` : traitement intelligent
  # (Phil, 2026-08-21), jamais un crash qui bloquerait tout le carnet pour une chanson en
  # défaut. `candidates` = blocs RÉELS du `.lyr` du même type (`block_kind`, "couplet" pour
  # "couplet-3" comme pour "couplet"), dans leur ordre RÉEL d'apparition (`lyr_order`,
  # dédupliqué : un refrain repris 3 fois n'y compte qu'une fois).
  # - Un SEUL candidat -> c'est forcément lui (typo de numéro, "{couplet}" pour l'unique
  #   couplet, etc.) : nom corrigé, signalé, on continue.
  # - Plusieurs candidats (ex. plusieurs `{couplet}` génériques dans le .gab, sans numéro) ->
  #   mapping POSITIONNEL : la Nième référence de ce type dans le .gab prend le Nième bloc
  #   de ce type dans le .lyr (`counters`, compteur par type sur TOUTE la construction de
  #   la chanson — un seul `Hash.new(0)` passé par `build`, jamais réinitialisé en cours de
  #   route).
  # - Aucun candidat (type inconnu du .lyr) -> conflict log, bloc vide rendu à la place.
  def self.fetch_block(lyr_blocks, name, lyr_order, counters)
    return lyr_blocks[name] if lyr_blocks.key?(name)

    kind = block_kind(name)
    candidates = lyr_order.uniq.select { |n| block_kind(n) == kind }

    if candidates.size == 1
      Layout.log_build("bloc .gab \"#{name}\" introuvable tel quel, corrigé en \"#{candidates.first}\" (seul bloc \"#{kind}\" du .lyr)")
      return lyr_blocks.fetch(candidates.first)
    end

    if candidates.size > 1
      counters[kind] += 1
      resolved = candidates[counters[kind] - 1]
      if resolved
        Layout.log_build("bloc .gab \"#{name}\" générique : #{counters[kind]}e référence \"#{kind}\" -> \"#{resolved}\" (ordre d'apparition dans le .lyr)")
        return lyr_blocks.fetch(resolved)
      end
    end

    Layout.conflict!("bloc \"#{name}\" introuvable (référencé dans le .gab, absent du .lyr)", solution: "bloc vide affiché")
    Block.new(lines: [], directives: {}, paired_with_previous: false)
  end

  # `name` peut être "nomA+nomB" (voir `parse_gab`, marque `+`) : concatène les lignes des
  # blocs dans l'ordre pour n'en faire qu'un seul, rendu comme un bloc normal.
  def self.resolve_block(lyr_blocks, name, lyr_order, counters)
    return fetch_block(lyr_blocks, name, lyr_order, counters) unless name.include?("+")

    parts = name.split("+").map { |n| fetch_block(lyr_blocks, n, lyr_order, counters) }
    Block.new(lines: parts.flat_map(&:lines), directives: parts.first.directives, paired_with_previous: false)
  end

  # "intro-1" -> "intro" (Phil, 2026-08-20 : "le premier mot dans un {...}, découpé selon
  # les '-', le deuxième élément étant souvent le numéro").
  def self.block_name_kind(name)
    name.split("-").first
  end

  # `intro_align` (layout du carnet, voir `CarnetBuilder::LAYOUTS`) : alignement par
  # défaut du bloc "intro" — un `block_align` déjà posé explicitement (`.gab`/directive)
  # garde TOUJOURS la priorité, jamais écrasé. Renvoie un bloc neuf (jamais de mutation en
  # place : `resolve_block` peut partager le même Hash `directives` entre plusieurs blocs
  # concaténés par "+").
  def self.with_intro_align(block, name, layout)
    return block unless layout && layout[:intro_align]
    return block if block.directives.key?(:block_align)
    return block unless block_name_kind(name) == "intro"

    Layout.log_build("bloc \"#{name}\" aligné #{layout[:intro_align]} (intro_align du layout)")
    Block.new(lines: block.lines, directives: block.directives.merge(block_align: layout[:intro_align].to_s), paired_with_previous: block.paired_with_previous)
  end

  # Orchestrateur .gab/.lyr/.infos : un dossier = une chanson + une mise en page. `.gab`
  # OPTIONNEL (voir `default_items`). page_count/first_page_no : voir `build_from_dsl`.
  # `layout:` (Hash title_band:/diag_position:/lyrics_flux:, voir `CarnetBuilder::LAYOUTS`
  # et Manuel/song/layout.adoc) : défauts du CARNET pour cette chanson — un `.gab` explicite
  # garde priorité (une chanson peut toujours s'écarter du layout général, Manuel : "on
  # peut le faire chanson par chanson ou de façon générale... ou les deux").
  def self.build(folder, out_path, page_size_in:, page_count:, first_page_no: 1, layout: nil)
    gab_path = FileFinder.find(folder, :gab)
    lyr_path = FileFinder.find(folder, :lyr)
    infos_path = FileFinder.find(folder, :inf)
    raise "fichiers .lyr/.lyrics ou .infos/.inf introuvables dans #{folder}" unless lyr_path && infos_path

    meta = parse_infos(infos_path)
    Layout.current_song = meta["title"] || File.basename(folder)
    Layout.current_page = first_page_no
    lyr_blocks, lyr_order = parse_lyr(lyr_path)
    if meta["transpose"]
      decalage_lettres, decalage_demitons = Transpose.parser_entete(meta["transpose"])
      ChordDiagrams.transpose_blocks!(lyr_blocks, decalage_lettres, decalage_demitons)
      Layout.log_build("transposition \"#{meta["transpose"]}\" appliquée (#{decalage_lettres} lettre(s)/#{decalage_demitons} demi-ton(s))")
    end
    title_band_default = layout&.key?(:title_band) ? layout[:title_band] : DEFAULT_TITLE_BAND
    diag_position_default = layout&.fetch(:diag_position, nil) || DEFAULT_DIAG_POSITION
    lyrics_flux = layout&.fetch(:lyrics_flux, nil) || :side
    Layout.log_build("layout résolu : title_band=#{title_band_default} diag_position=#{diag_position_default} lyrics_flux=#{lyrics_flux} (source=#{layout ? "carnet" : "défauts app"})")
    if gab_path
      Layout.log_build(".gab trouvé (#{gab_path}) : mise en page explicite, layout du carnet ignoré pour l'agencement")
      items = parse_gab(gab_path)
    else
      Layout.log_build("agencement auto (default_items, RAO5 pairage par type)")
      items = default_items(lyr_blocks, lyr_order, title_band: title_band_default, diag_position: diag_position_default, lyrics_flux: lyrics_flux)
    end
    page_size = page_size_in.map { |v| v * 72 }
    page_w_pt, page_h_pt = page_size
    kdp = KDP.new(page_count: page_count, trim_width: page_size_in[0], trim_height: page_size_in[1],
      paper: Layout::KDP_PAPER, bleed: Layout::KDP_BLEED)

    Prawn::Document.generate(out_path, page_size: page_size, margin: 0) do |pdf|
      Layout.register_fonts(pdf)
      Layout.apply_kdp_margins(pdf, kdp, first_page_no, page_w_pt, page_h_pt)
      title_item = items.find { |i| i.type == :title }
      # `.gab` explicite sans directive `{title: ...}` (ex. w.gab de "À bicyclette") :
      # retombe sur `title_band_default` (layout résolu du carnet), jamais un :inline
      # imposé en silence — bug constaté 2026-08-22 : chanson sans bandeau alors que le
      # carnet le demande, simplement parce que son .gab ne redéfinit pas le titre.
      header_style = if title_item
        title_item.data[:title] == "band" ? :band : :inline
      else
        title_band_default ? :band : :inline
      end
      header_bottom = header_style == :band ? Layout.draw_header_band(pdf, meta) : Layout.draw_header_inline(pdf, meta)
      Layout.log_build("titre en #{header_style == :band ? "bandeau" : "ligne simple"} (header_style)")

      chord_frets = ChordDiagrams.collect_chord_frets(lyr_blocks.values)
      diag_paths = chord_frets.filter_map { |chord, fret| ChordDiagrams.diag_path(chord, fret: fret) }
      diag_position = (items.find { |i| i.type == :diags }&.data&.dig(:position) || diag_position_default).to_sym
      Layout.log_build("#{diag_paths.size} diagramme(s) d'accord, position=#{diag_position}")

      text_x, text_w, first_avail_h, side_col = Layout.layout_diags(pdf, diag_paths, diag_position, header_bottom)

      chord_ascent = Layout.font_metric(pdf, Layout::CHORD_SIZE) { pdf.font.ascender }
      text_ascent = Layout.font_metric(pdf, Layout::TEXT_SIZE) { pdf.font.ascender }
      text_descent = Layout.font_metric(pdf, Layout::TEXT_SIZE) { pdf.font.descender }

      bare_kind_counters = Hash.new(0)
      rows = items.select { |i| i.type == :row }.map { |i| i.data.map { |name| with_intro_align(resolve_block(lyr_blocks, name, lyr_order, bare_kind_counters), name, layout) } }
      col1_w, col2_w, h_gutter = Layout.row_column_widths(pdf, rows, text_w)

      row_idx = 0
      elements = []
      shrink_jobs = [] # {index:, svg_path:, align:, title:} — tablas à réduire si besoin
      items.each do |item|
        case item.type
        when :row
          elements.concat(Layout.build_row_or_split(pdf, rows[row_idx], text_x, text_w, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent))
          row_idx += 1
        when :tabla
          name = item.data[:tabla]
          svg_path = ensure_tabla_svg(folder, name)
          next unless svg_path

          align = item.data[:align]
          title = item.data[:title]
          elements << Layout.build_tabla_element_v2(pdf, svg_path, text_x, text_w, align: align, title: title)
          if item.data[:shrink] == "true"
            shrink_jobs << { index: elements.size - 1, svg_path: svg_path, align: align, title: title }
          end
        end
      end

      # `shrink` : RESPECTE la position choisie par l'auteur du .gab — jamais déplacée par
      # la pagination (épinglée), seulement réduite si besoin. L'espace qui lui revient
      # est calculé avec sa hauteur NATURELLE (pas simulée à 0 : sinon la pagination des
      # AUTRES éléments se trompe aussi, en pensant qu'il y a plus de place libre qu'il
      # n'y en aura réellement — vu en pratique, ça faisait remonter la page suivante sur
      # celle-ci). Ainsi la page d'à côté ne peut jamais déborder sur celle-ci
      # (Phil, 2026-08-16).
      pinned = shrink_jobs.map { |j| j[:index] }
      shrink_jobs.each do |job|
        pages = Layout.paginate(elements, first_avail_h, pdf.bounds.height, pinned: pinned)
        page = pages.find { |p| (p[:start]...p[:finish]).cover?(job[:index]) }
        others_h = (page[:start]...page[:finish]).sum { |j| j == job[:index] ? 0 : elements[j].height }
        max_h = page[:avail_h] - others_h
        next if elements[job[:index]].height <= max_h

        Layout.log_build("tabla \"#{job[:title] || job[:svg_path]}\" (shrink: true) réduite à #{max_h.round(1)}pt de haut pour tenir sur sa page")
        elements[job[:index]] = Layout.build_tabla_element_v2(
          pdf, job[:svg_path], text_x, text_w, align: job[:align], title: job[:title], max_height: max_h
        )
      end

      Layout.paginate_and_draw(pdf, elements, first_avail_h, kdp: kdp, page_w_pt: page_w_pt, page_h_pt: page_h_pt, first_page_no: first_page_no, pinned: pinned, side_col: side_col, text_x: text_x, text_w: text_w)
    end
  end

  # Chemin legacy : chanson en un seul fichier `.dsl` (frontmatter YAML + blocs), voir
  # `DSLParser`. page_size_in : [largeur, hauteur] en pouces. header_style: :inline (titre +
  # infos sur la ligne du titre, fond page) ou :band (bandeau foncé pleine page en haut,
  # texte clair). page_count: nombre de pages TOTAL du carnet (détermine la marge de
  # reliure KDP, cf. `KDP#gutter_margin`) ; first_page_no: numéro de la première page de
  # cette chanson dans le carnet complet (recto/verso, numérotation).
  def self.build_from_dsl(dsl_path, out_path, page_size_in:, page_count:, header_style: :inline, first_page_no: 1)
    song = DSLParser.parse(File.read(dsl_path))
    chord_frets = ChordDiagrams.collect_chord_frets(song.blocks)
    page_size = page_size_in.map { |v| v * 72 }
    page_w_pt, page_h_pt = page_size
    kdp = KDP.new(page_count: page_count, trim_width: page_size_in[0], trim_height: page_size_in[1],
      paper: Layout::KDP_PAPER, bleed: Layout::KDP_BLEED)

    Prawn::Document.generate(out_path, page_size: page_size, margin: 0) do |pdf|
      Layout.register_fonts(pdf)
      Layout.apply_kdp_margins(pdf, kdp, first_page_no, page_w_pt, page_h_pt)
      header_bottom = header_style == :band ? Layout.draw_header_band(pdf, song.meta) : Layout.draw_header_inline(pdf, song.meta)

      diag_paths = chord_frets.filter_map { |chord, fret| ChordDiagrams.diag_path(chord, fret: fret) }
      diag_w = Layout::DIAG_W
      diag_heights = diag_paths.map { |p| Layout.svg_height_for(File.read(p), diag_w) }

      # Essai 1 : page recto — "intérieur" (côté reliure) = gauche.
      diag_col_w = diag_w + Layout::DIAG_TEXT_GAP
      text_x = diag_col_w
      text_w = pdf.bounds.width - diag_col_w

      Layout.draw_diags(pdf, diag_paths, diag_heights, x: 0, avail_h: header_bottom, width: diag_w)

      chord_ascent = Layout.font_metric(pdf, Layout::CHORD_SIZE) { pdf.font.ascender }
      text_ascent = Layout.font_metric(pdf, Layout::TEXT_SIZE) { pdf.font.ascender }
      text_descent = Layout.font_metric(pdf, Layout::TEXT_SIZE) { pdf.font.descender }
      cote_a_cote = song.meta.fetch("cote_a_cote", true)

      elements = Layout.build_row_elements(pdf, song.blocks, text_x, text_w, chord_ascent, text_ascent, text_descent, cote_a_cote)
      tabla_el = Layout.build_tabla_element(pdf, song.meta, dsl_path, text_x, text_w)
      elements << tabla_el if tabla_el

      Layout.paginate_and_draw(pdf, elements, header_bottom, kdp: kdp, page_w_pt: page_w_pt, page_h_pt: page_h_pt, first_page_no: first_page_no)
    end
  end
end
