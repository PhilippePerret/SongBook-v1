require "fileutils"
require "yaml"
require_relative "dsl_parser"
require_relative "layout"
require_relative "chord_diagrams"
require_relative "transpose"
require_relative "printer_profile"
require_relative "locale"
require_relative "file_finder"
require_relative "diags_sync"
require_relative "../tools/tablator/tablator"

# Construit les pages PDF d'UNE chanson — point d'entrée réutilisable (API : "je veux
# juste cette chanson"), orchestrant `DSLParser`/le format `.lyr`+`.gab`+`.infos`,
# `ChordDiagrams` (résolution des diagrammes) et `Layout` (mise en page/dessin).
module PageBuilder
  TABLATOR_PATHS = Dir.glob(File.expand_path("../tools/tablator/*.rb", __dir__))

  # Un fichier YAML par layout sous `assets/layouts/` (nom de fichier = nom du layout,
  # ex. `regular-B.yaml`) — ajouter/modifier un layout ne touche jamais aux autres.
  # `_default.yaml` : valeurs par défaut, jamais un layout nommé lui-même — chaque layout
  # part de ces valeurs et n'a besoin de définir que ses écarts. SEULE source des défauts
  # de layout (`DEFAULT_TITLE_BAND`/`DEFAULT_DIAG_POSITION` ci-dessous en dérivent —
  # jamais une valeur écrite une 2e fois en dur).
  LAYOUTS_DIR = File.expand_path("../assets/layouts", __dir__)

  def self.load_layout_yaml(path)
    (YAML.safe_load_file(path, symbolize_names: false) || {}).each_with_object({}) do |(k, v), layout|
      layout[k.to_sym] = v.is_a?(String) ? v.to_sym : v
    end
  end

  DEFAULT_LAYOUT = load_layout_yaml(File.join(LAYOUTS_DIR, "_default.yaml")).freeze
  # Sans `layout:` posé dans le `.infos` du carnet — jamais le `_default.yaml` brut
  # (incomplet, pensé comme socle commun), un VRAI layout nommé.
  DEFAULT_LAYOUT_NAME = "regular-B"

  LAYOUTS = Dir.glob(File.join(LAYOUTS_DIR, "*.yaml")).each_with_object({}) do |path, h|
    name = File.basename(path, ".yaml")
    next if name == "_default"

    h[name] = DEFAULT_LAYOUT.merge(load_layout_yaml(path))
  end.freeze

  # Clés canoniques (anglais) attendues par le gabarit : title/year/lyrics/composer/performer.
  # Table des alias construite en INVERSANT `Loc.get` sur ces clés  :
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
  # tolérées  : "tu les prends comme possibles dans le code" — pas de
  # réécriture de fichier imposée) : n'écrasent JAMAIS la clé canonique si elle est déjà
  # présente.

  def self.parse_infos(path)
    meta = {}
    File.foreach(path) do |line|
      k, v = line.strip.split(":", 2)
      meta[k.strip] = v.strip if k && v && !k.strip.empty? && !v.strip.empty?
    end
    # `meta[canon] ||= meta[alt]` créerait la clé canonique à `nil` même quand NI la
    # clé canonique NI son alias ne sont dans le fichier (`Hash#[]=` fixe TOUJOURS la
    # clé) — un `.infos` indexé partiel (juste `font-size:`, par ex.) se retrouvait
    # avec `title`/`performer`/... explicitement à `nil`, qui EFFAÇAIENT ceux de la
    # chanson une fois fusionnés (`Hash#merge`, `nil` explicite gagne toujours).
    infos_key_aliases.each { |alt, canon| meta[canon] = meta[alt] if !meta.key?(canon) && meta.key?(alt) }
    meta
  end

  # `.lyr` : couplets — chaque paragraphe commence par `{nom}` (SANS ":", à ne pas confondre
  # avec une directive `{clé: valeur}`), suivi des lignes accord/texte. Le nom est OPTIONNEL
  # (règle : rien ne doit être impossible) — un paragraphe sans `{nom}` reçoit
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
  # au lieu d'écraser (perte de contenu, interdit), le 2nd est renommé en
  # suffixe (`nom-2`, `nom-3`...) pour que les deux soient rendus.
  # Un paragraphe = un bloc, séparé normalement par une ligne vide — MAIS une ligne
  # `{nom}` démarre TOUJOURS un nouveau bloc, MÊME collée SANS ligne vide à la strophe
  # précédente, MÊME collée à la fin de la dernière ligne de texte (aucun saut de ligne
  # du tout — , "Au fur et à mesure" : "Je t'écris des mots purs…{final}",
  # `{final}` sur la MÊME ligne que "purs…", jamais reconnu). `line.split` sur le motif
  # d'en-tête AVEC capture isole "{nom}" de ce qui l'entoure sur la même ligne, dans
  # l'ordre — le texte qui précède reste rattaché au bloc EN COURS, "{nom}" ouvre le
  # suivant.
  def self.split_lyr_paragraphs(text)
    paragraphs = []
    current = []
    text.each_line do |raw_line|
      line = raw_line.chomp
      if line.strip.empty?
        paragraphs << current.join("\n") unless current.empty?
        current = []
        next
      end
      # `{nom}` OU `{nom; clé: valeur; ...}` (ex. `{intro; label: "INTRO"}`, la
      # dernière propriété peut ne pas avoir de ";" final) : mêmes directives inline
      # que le `.gab` (`row_col_name`) — `[^:;}]+` seul ratait toute forme avec
      # directives, laissée telle quelle comme parole (bug constaté, issue #68 :
      # `{intro; label: INTRO;}` s'écrivait en toutes lettres dans le PDF).
      line.split(/(\{[^{}]+\})/).reject(&:empty?).each do |seg|
        if seg =~ /\A\{[^{}]+\}\z/ && !current.empty?
          paragraphs << current.join("\n")
          current = []
        end
        current << seg
      end
    end
    paragraphs << current.join("\n") unless current.empty?
    paragraphs.map(&:strip).reject(&:empty?)
  end

  def self.parse_lyr(path)
    blocks = {}
    order = []
    raw_bodies = {}
    paragraphs = split_lyr_paragraphs(File.read(path))
    paragraphs.each_with_index do |para, i|
      lines = para.split("\n")
      header = lines.first
      if header =~ /\A\{([^:;}]+)(?:;([^}]*))?\}\z/
        given_name = Regexp.last_match(1).strip
        dirs = parse_header_directives(Regexp.last_match(2))
        body = lines[1..] || []
      else
        given_name = nil
        dirs = {}
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
      # `label:` (issue #63, ex. `{refrain-1; label: REFRAIN}`) : PAS une ligne du corps —
      # étiquette dessinée EN REGARD, À GAUCHE de la 1re ligne de la strophe
      # (`Layout.draw_block`), jamais dans le flux des paroles.
      blocks[name] = Block.new(lines: body.map { |l| build_lyr_line(l) }, directives: dirs, paired_with_previous: false)
    end
    [blocks, order]
  end

  # `{nom; clé: valeur; clé2: valeur2}` : directives inline en tête de bloc `.lyr` — même
  # syntaxe que `row_col_name` (`.gab`), dernière propriété SANS ";" final acceptée (`str`
  # peut être `nil`, aucune directive).
  def self.parse_header_directives(str)
    str.to_s.split(";").each_with_object({}) do |pair, dirs|
      k, v = pair.split(":", 2)
      next unless k && v && !k.strip.empty?

      dirs[k.strip.to_sym] = v.strip.gsub(/\A["']|["']\z/, "")
    end
  end

  # Ligne ENTIÈREMENT entourée de crochets (ex. `[Intro : /Em://Em9:]`) : étiquette, pas
  # des paroles — toujours sur une seule ligne (règle trouvée dans le .lyr d'"À bicyclette",
  # jamais accords au-dessus/texte en dessous. Les crochets eux-mêmes ne
  # sont que la marque de syntaxe, jamais affichés. Aucune ambiguïté possible avec les
  # crochets de basse d'accord (`/accord[basse]:`, voir Manuel/song/chords.adoc) : ceux-là
  # sont TOUJOURS précédés de `/`, jamais en tout début de ligne.
  def self.build_lyr_line(raw)
    stripped = raw.strip
    if stripped.start_with?("[") && stripped.end_with?("]")
      Line.new(segments: DSLParser.parse_line(stripped[1...-1]), label: true)
    else
      Line.new(segments: DSLParser.parse_line(raw))
    end
  end

  GabItem = Struct.new(:type, :data)

  # `.gab` : suite de paragraphes — soit une directive `{clé: valeur; ...}` (classée par la
  # clé qu'elle porte : titre/tabla/diags), soit une row de contenu `{song: nom}` (une ou
  # deux, séparées par `//` pour le côte-à-côte, comme le `//` du DSL simple), soit une row
  # de blocs `.lyr` référencés DIRECTEMENT par leur nom `{nom}` (sans `song:`) — `+` entre
  # deux `{nom}` CONCATÈNE leurs paroles en un seul bloc rendu  : forcer
  # un pseudo-refrain coupé en plusieurs blocs à s'afficher comme un seul, à côté d'un
  # couplet, via `//`). Ex. `{couplet-1} // {refrain-part1-1} + {refrain-part2-1}`.
  # `{nom; clé:valeur;}` : directive(s) inline sur UN bloc précis d'une row — bug constaté
  # 2026-08-23 (Phil, "À bicyclette") : `{intro; align:Right;} + {couplet-1}` silencieusement
  # transformé en item `:unknown` (donc disparu du rendu, contenu perdu) — l'ancienne regex
  # excluait `:`/`;` de CHAQUE token, jamais seulement de la partie nom.
  ROW_TOKEN_RE = /\A\{[^:;}]+(?:;[^}]*)?\}(\s*\+\s*\{[^:;}]+(?:;[^}]*)?\})*\z/.freeze

  # Une ligne = un paragraphe (contrairement au `.lyr`, où une strophe peut s'étaler sur
  # plusieurs lignes et a donc besoin d'une ligne vide pour savoir où elle s'arrête — un
  # paragraphe `.gab` tient TOUJOURS sur une seule ligne, `{nom}`/`{song: nom}`/directive,
  # jamais ambigu : exiger une ligne vide entre chaque n'avait pas de sens ici, imposé sans
  # concertation par une session précédente — retiré). Lignes vides
  # tolérées (ignorées), ni obligatoires ni interdites.
  # `{nom; tab: ...}` / `{nom; score: ...}` / `{nom; image: ...}` : forme déclarative
  # (nom en tête suivi d'attributs) — malgré le nom en tête qui la fait matcher
  # ROW_TOKEN_RE, PAS une row de paroles : une ressource (tabla/score/image).
  RESOURCE_DECLARATION_RE = /;\s*(?:tab|score|image)\s*:/.freeze

  # Une seule marque `{nom; tab/score/image: ...}` (déjà isolée par l'appelant, que ce
  # soit la ligne entière ou une seule colonne d'un `//`) -> l'item ressource.
  def self.parse_resource_declaration(chunk)
    inner = chunk[/\A\{(.*)\}\z/m, 1] || ""
    segments = inner.split(";")
    # Nom en tête sans ":" (ex. "intro" dans "{intro; tab: intro;...}") : un identifiant
    # (Manuel/song/gabarit.adoc, "on lui trouve un identifiant unique"), JAMAIS un titre
    # par défaut — seul `title:` explicite affiche quelque chose.
    dirs = {}
    segments.each do |pair|
      k, v = pair.split(":", 2)
      next unless k && v && !k.strip.empty?

      key = k.strip.to_sym
      key = :tabla if key == :tab
      dirs[key] = v.strip.gsub(/\A["']|["']\z/, "")
    end
    type = %i[tabla score image].find { |k| dirs.key?(k) } || :unknown
    GabItem.new(type, dirs)
  end

  # Une colonne (résultat d'un split sur `//`) qui est un `{nom}`/`{nom-N}` de paroles
  # (jamais une ressource, voir `RESOURCE_DECLARATION_RE`) -> son nom ("nomA+nomB" si
  # concaténée), les directives inline (`{nom; clé:valeur;}`) posées dans `row_directives`.
  def self.row_col_name(col, row_directives)
    return nil unless col =~ ROW_TOKEN_RE

    col.scan(/\{([^:;}]+)(?:;([^}]*))?\}/).map do |name, dirs_str|
      name = name.strip
      dirs_str.to_s.split(";").each do |pair|
        k, v = pair.split(":", 2)
        next unless k && v && !k.strip.empty?

        (row_directives[name] ||= {})[k.strip.to_sym] = v.strip.gsub(/\A["']|["']\z/, "")
      end
      name
    end.join("+")
  end

  # Ligne `//` mêlant AU MOINS une marque ressource (`tab:`/`score:`/`image:`) et
  # d'autres colonnes (paroles) : `//` veut dire côte à côte PARTOUT dans ce format,
  # quel que soit ce qu'il y a de chaque côté — un seul item `:side_by_side`, chaque
  # colonne restant elle-même (`:resource` ou `:lyrics`), voir `build_song_elements`
  # (chaque colonne devient son propre élément — position + taille — combinés ensuite,
  # sans se soucier de leur nature).
  def self.split_gab_row_with_resources(para)
    columns = para.split("//").map(&:strip).map do |col|
      if col =~ RESOURCE_DECLARATION_RE
        item = parse_resource_declaration(col)
        { kind: :resource, item: item }
      else
        directives = {}
        name = row_col_name(col, directives)
        { kind: :lyrics, names: [name].compact, directives: directives }
      end
    end
    GabItem.new(:side_by_side, { columns: columns })
  end

  def self.parse_gab(path)
    File.read(path).split("\n").map(&:strip).reject(&:empty?).flat_map do |para|
      if para.include?("{song:")
        names = para.split("//").filter_map { |chunk| chunk[/\{song:\s*([^;}]+)/, 1]&.strip }
        [GabItem.new(:row, { names: names, directives: {} })]
      elsif para.include?("//") && para.split("//").any? { |c| c.strip =~ RESOURCE_DECLARATION_RE }
        [split_gab_row_with_resources(para)]
      elsif !para.include?("//") && para =~ RESOURCE_DECLARATION_RE
        [parse_resource_declaration(para)]
      # `{diags; position: End;}` : "diags" en tête SANS ":" (même forme que
      # `{intro; tab: ...}` ci-dessus) matchait `ROW_TOKEN_RE` et se faisait chercher
      # comme un bloc de paroles nommé "diags" dans le `.lyr` (bug constaté : "bloc
      # diags introuvable"). "diags" n'est PAS un nom de bloc possible (mot réservé,
      # position des diagrammes), intercepté ici en premier.
      elsif para =~ /\A\{\s*diags\s*(;|\})/i
        inner = para[/\A\{(.*)\}\z/m, 1] || ""
        dirs = {}
        inner.split(";")[1..].to_a.each do |pair|
          k, v = pair.split(":", 2)
          next unless k && v && !k.strip.empty?

          dirs[k.strip.to_sym] = v.strip.gsub(/\A["']|["']\z/, "")
        end
        [GabItem.new(:diags, dirs)]
      elsif (cols = para.split("//").map(&:strip)).all? { |c| c =~ ROW_TOKEN_RE }
        row_directives = {}
        names = cols.map { |c| row_col_name(c, row_directives) }
        [GabItem.new(:row, { names: names, directives: row_directives })]
      else
        inner = para[/\A\{(.*)\}\z/m, 1] || ""
        dirs = {}
        inner.split(";").each do |pair|
          k, v = pair.split(":", 2)
          next unless k && v && !k.strip.empty?

          # "tab" = diminutif toléré pour "tabla" — même convention que les formes
          # longues/courtes déjà tolérées ailleurs (`FileFinder`).
          key = k.strip.to_sym
          key = :tabla if key == :tab
          dirs[key] = v.strip.gsub(/\A["']|["']\z/, "")
        end
        # `tabla`/`score`/`image`/`diags` avant `title` : leur directive porte elle-même
        # une clé `title` (sa légende) — sinon elle se ferait passer pour la config d'en-tête.
        type = %i[tabla score image diags title].find { |k| dirs.key?(k) } || :unknown
        [GabItem.new(type, dirs)]
      end
    end
  end

  # Génère le SVG de la tabla à la demande si absent, ou si le/les `.tab` source(s)
  # sont plus récent(s) que le `.svg` déjà là (cache invalidé par date de fichier).
  # `name` sans extension — "intro+couplet"  : FUSION, pure mise
  # bout à bout des CODES de "intro.tab" et "couplet.tab" (frontmatter du 1er fichier
  # repris tel quel, corps concaténés), un SEUL SVG produit ("intro+couplet.svg").
  # Renvoie le chemin du SVG, ou nil si les sources nécessaires n'existent pas toutes.
  # Dossiers RÉELS des ressources (tab/score/image) d'une chanson, dans l'ordre de
  # recherche : `/scores`, `/images`, racine du dossier chanson, PUIS tous les
  # sous-dossiers (récursif — jamais des milliers de fichiers dans une chanson
  # si toujours introuvable.
  RESOURCE_SUBDIRS = %w[scores images].freeze

  def self.resource_search_dirs(folder)
    RESOURCE_SUBDIRS.map { |d| File.join(folder, d) }.select { |d| File.directory?(d) } << folder
  end

  def self.locate_resource(folder, filename)
    resource_search_dirs(folder).each do |dir|
      path = File.join(dir, filename)
      return path if File.exist?(path)
    end
    Dir.glob(File.join(folder, "**", filename)).first
  end

  # Cache invalidé si un `.tab` source OU l'outil `tablator.rb` lui-même a changé depuis
  #  : SVG jamais régénéré après une correction de tablator.rb, comparé
  # seulement au `.tab` — bug constaté, servait un SVG périmé).
  def self.svg_fresh?(svg_path, *source_paths)
    File.exist?(svg_path) && (source_paths + TABLATOR_PATHS).all? { |p| File.mtime(p) <= File.mtime(svg_path) }
  end

  # `name` sans extension — "intro+couplet"  : FUSION, mise bout à
  # bout de "intro.tab" et "couplet.tab" ; chaque source garde SA PROPRE métrique/
  # unité  : "changement de métrique d'un segment à l'autre" —
  # "amorce" en 3/4, la suite en 4/4 — jamais celle du 1er fichier imposée aux
  # autres, voir `Tablator.parse_source_measures`). Renvoie [contenus (liste, 1
  # par source, dans l'ordre), dossier_de_sortie, .tab source(s)], ou nil si une
  # source manque.
  def self.tab_source_content(folder, name)
    if name.include?("+")
      tab_paths = name.split("+").map { |n| locate_resource(folder, "#{n}.tab") }
      return nil unless tab_paths.all?

      [tab_paths.map { |p| File.read(p) }, File.dirname(tab_paths.first), tab_paths]
    else
      tab_path = locate_resource(folder, "#{name}.tab")
      return nil unless tab_path

      [[File.read(tab_path)], File.dirname(tab_path), [tab_path]]
    end
  end

  # SVG généré à la demande (`Tablator.render_tab_svg` — rendu géométrique direct,
  # plus de dépendance LilyPond), UN FICHIER PAR SYSTÈME (Phil,
  # 2026-08-28 : "chaque système doit être un élément de pagination indépendant" —
  # 2 systèmes peuvent tenir sur une page, le suivant passer sur la page d'après ;
  # `build_song_elements` pousse donc un `PageElement` par système). Cache : la
  # fraîcheur du 1er fichier (`.s1.svg`) sert de sentinelle pour tout le lot (écrits
  # ensemble, dans le même appel). `measures_override` : option `tabs_measures_per_page`,
  # prime sur le calcul automatique. Écrits dans `<chanson>/.export/`
  #  : jamais les fichiers générés dans le dossier de l'user,
  # `scores/` reste UNIQUEMENT ses `.tab`).
  EXPORT_DIRNAME = ".export"

  def self.ensure_tabla_svg(folder, name, available_width_pt, measures_override: nil)
    content, _out_dir, source_paths = tab_source_content(folder, name)
    return [] unless content

    export_dir = File.join(folder, EXPORT_DIRNAME)
    FileUtils.mkdir_p(export_dir)

    # Le preset actif (`Tablator.active_preset`) fait partie de la clé de cache —
    # sinon un changement de preset , "mini-tablatures") sert un
    # SVG périmé tant que les sources .tab n'ont pas changé.
    key = "#{Tablator.active_preset}.#{measures_override ? "mo#{measures_override}" : "w#{available_width_pt.round}"}"
    first_path = File.join(export_dir, "#{name}.#{key}.s1.svg")
    if svg_fresh?(first_path, *source_paths)
      return Dir.glob(File.join(export_dir, "#{name}.#{key}.s*.svg")).sort_by { |p| p[/\.s(\d+)\.svg\z/, 1].to_i }
    end

    results = Tablator.render_tab_svg(content, available_width_pt: available_width_pt, measures_per_line: measures_override)
    results.each_with_index.map do |result, i|
      svg_path = File.join(export_dir, "#{name}.#{key}.s#{i + 1}.svg")
      File.write(svg_path, result[:svg])
      svg_path
    end
  end

  # `score:`/`image:` : pas de génération (contrairement à `tab:`/`ensure_tabla_svg` —
  # aucun outil ne produit encore de partition, `Manuel/song/tablas-et-scores.adoc`), le
  # fichier doit déjà exister sous ce nom (`locate_resource`). Extension devinée (Phil,
  # 2026-08-27 : "faciliter le travail de l'user", jamais à préciser dans la directive) —
  # SVG cherché en premier (notation vectorielle), sinon image matricielle
  # (`Layout::RASTER_EXTENSIONS`).
  RESOURCE_EXTENSIONS = ["svg", *Layout::RASTER_EXTENSIONS.map { |e| e.delete_prefix(".") }].freeze

  def self.find_resource_asset(folder, name, kind)
    RESOURCE_EXTENSIONS.each do |ext|
      path = locate_resource(folder, "#{name}.#{ext}")
      return path if path
    end

    Layout.conflict!("#{kind} \"#{name}\" introuvable (#{name}.{#{RESOURCE_EXTENSIONS.join(",")}})", solution: "élément ignoré")
    nil
  end

  # Valeurs par défaut  : "le moins de définitions possibles" — un `.gab`
  # ne sert qu'à ÉCARTER ces défauts, jamais à les répéter). Dérivées de `DEFAULT_LAYOUT`
  # (`_default.yaml`), jamais réécrites en dur ici.
  DEFAULT_TITLE_BAND = DEFAULT_LAYOUT.fetch(:title_band)
  DEFAULT_DIAG_POSITION = DEFAULT_LAYOUT.fetch(:diags_position).to_s
  DEFAULT_DIAG_ALIGN = DEFAULT_LAYOUT.fetch(:diags_align).to_s

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

  # `title_band`/`diags_position` : défauts de CE dossier (Manuel/song/layout.adoc, voir
  # `title_band`/`diags_position` par défaut, remplacés par le `layout:` du carnet quand
  # il est fourni — voir `build`). `lyrics_flux: :side` (défaut, "côte à côte") pair les
  # blocs 2 par 2 comme avant ; `:vertical` ("l'une en dessous de l'autre", layouts Column/
  # Column-B) ne pair jamais, chaque bloc a sa propre row. `:free` pas encore implémenté.
  def self.default_items(lyr_blocks, order, title_band: DEFAULT_TITLE_BAND, diag_position: DEFAULT_DIAG_POSITION, diag_align: DEFAULT_DIAG_ALIGN, lyrics_flux: :side)
    items = [GabItem.new(:title, { title: title_band ? "band" : "inline" }), GabItem.new(:diags, { position: diag_position, align: diag_align })]
    names = order.reject { |name| lyr_blocks.fetch(name).lines.empty? }

    raise "lyrics_flux :free (Manuel/song/layout.adoc) pas encore implémenté" if lyrics_flux == :free

    if lyrics_flux == :vertical
      Layout.log_build("lyrics_flux=:vertical : #{names.size} bloc(s), chacun sa propre row")
      names.each { |name| items << GabItem.new(:row, { names: [name], directives: {} }) }
      return items
    end

    pending = nil
    names.each do |name|
      if pending && block_kind(pending) == block_kind(name)
        Layout.log_build("blocs \"#{pending}\"+\"#{name}\" pairés côte à côte (RAO5, même type \"#{block_kind(name)}\")")
        items << GabItem.new(:row, { names: [pending, name], directives: {} })
        pending = nil
      else
        items << GabItem.new(:row, { names: [pending], directives: {} }) if pending
        pending = name
      end
    end
    items << GabItem.new(:row, { names: [pending], directives: {} }) if pending
    items
  end

  # Bloc `.gab` référencé introuvable TEL QUEL dans le `.lyr` : traitement intelligent
  # , jamais un crash qui bloquerait tout le carnet pour une chanson en
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
  # `row_directives` (voir `parse_gab`, `{nom; clé:valeur;}`) : directives inline posées sur
  # UN nom précis de la row — appliquées LIGNE PAR LIGNE, seulement aux lignes de CE
  # sous-bloc (`nomA`), jamais à celles d'un autre sous-bloc concaténé avec lui via "+"
  #  : "la ligne contenant l'intro doit être alignée à droite", PAS le
  # couplet-1 qui la suit dans "{intro; align:Right;} + {couplet-1}").
  def self.resolve_block(lyr_blocks, name, lyr_order, counters, row_directives: {})
    return apply_extra_directives(fetch_block(lyr_blocks, name, lyr_order, counters), name, row_directives) unless name.include?("+")

    parts = name.split("+").map { |n| apply_extra_directives(fetch_block(lyr_blocks, n, lyr_order, counters), n, row_directives) }
    Block.new(lines: parts.flat_map(&:lines), directives: parts.first.directives, paired_with_previous: false)
  end

  def self.apply_extra_directives(block, name, row_directives)
    dirs = row_directives[name]
    return block if dirs.nil? || dirs.empty?

    align = dirs[:align]
    lines = align ? block.lines.map { |l| Line.new(segments: l.segments, label: l.label, align: align) } : block.lines
    Block.new(lines: lines, directives: block.directives.merge(dirs), paired_with_previous: block.paired_with_previous)
  end

  # "intro-1" -> "intro"  : "le premier mot dans un {...}, découpé selon
  # les '-', le deuxième élément étant souvent le numéro").
  def self.block_name_kind(name)
    name.split("-").first
  end

  # `intro_align` (option, voir `Options`) : alignement par défaut du bloc "intro" — un
  # `block_align` déjà posé explicitement (`.gab`/directive) garde TOUJOURS la priorité,
  # jamais écrasé. Renvoie un bloc neuf (jamais de mutation en place : `resolve_block`
  # peut partager le même Hash `directives` entre plusieurs blocs concaténés par "+").
  def self.with_intro_align(block, name)
    return block unless Options.explicit?(:intro_align)
    return block if block.directives.key?(:block_align)
    return block unless block_name_kind(name) == "intro"

    align = Options.get(:intro_align)
    Layout.log_build("bloc \"#{name}\" aligné #{align} (intro_align)")
    Block.new(lines: block.lines, directives: block.directives.merge(block_align: align.to_s), paired_with_previous: block.paired_with_previous)
  end

  # Construit `elements` (rows + tablas, dans l'ordre de `items`) pour UNE position
  # donnée (`text_x`) — appelé une fois pour une position fixe, deux fois (gauche/droite)
  # pour une position dynamique `int`/`ext` (voir `build`). `rows` déjà résolu
  # (`resolve_block`/`with_intro_align`, compteurs `bare_kind_counters`) — ne dépend pas
  # de `text_x`, jamais recalculé ici (fausserait le mapping positionnel des blocs
  # génériques si appelé deux fois).
  # Échelle UNIFORME pour TOUTE la chanson  : "on l'applique à TOUTES")
  # — jamais tabla par tabla. Chaque tab/score vectoriel a une largeur physique NATURELLE
  # (calculée directement par `Tablator.render_tab_svg` — plus de
  # dépendance LilyPond) : un seul facteur de réduction (si la plus large dépasse la
  # colonne) s'applique à toutes (`Layout.uniform_tab_scale`).
  # `name`/`item.type` -> chemins SVG : `ensure_tabla_svg` pour `:tabla`/`:score`
  # vectoriel (liste à 1 élément), `find_resource_asset` pour `:image`/`:score`
  # matriciel (un seul chemin, pas de génération). `nil` si introuvable.
  def self.notation_asset_paths(item, folder, text_w)
    name = item.data[item.type]
    if item.type == :tabla
      paths = ensure_tabla_svg(folder, name, text_w, measures_override: Options.get(:tabs_measures_per_page))
      paths.empty? ? nil : paths
    else
      path = find_resource_asset(folder, name, item.type)
      return nil unless path

      if Layout.raster_image?(path)
        path
      else
        paths = ensure_tabla_svg(folder, name, text_w, measures_override: Options.get(:tabs_measures_per_page))
        paths.empty? ? nil : paths
      end
    end
  end

  def self.notation_scale(items, folder, text_w)
    svgs = items.flat_map do |item|
      next [] unless item.type == :tabla || item.type == :score

      paths = notation_asset_paths(item, folder, text_w)
      next [] if paths.nil? || !paths.is_a?(Array)

      paths.map { |p| File.read(p) }
    end
    Layout.uniform_tab_scale(svgs, text_w)
  end

  # Ressource (tabla/score/image) -> ses éléments de pagination, à la position/taille
  # données (`x0`/`width` — jamais `text_x`/`text_w` en dur : réutilisé aussi bien pour
  # une ressource pleine largeur qu'une colonne d'un `:side_by_side`, voir plus bas).
  # `shrink_jobs` renvoyés avec un index LOCAL (position dans le tableau `elements`
  # renvoyé) — à l'appelant de le décaler une fois fusionné dans son propre tableau.
  def self.build_resource_page_elements(pdf, item, folder, x0, width, tab_scale)
    asset_paths = notation_asset_paths(item, folder, width)
    return [[], []] unless asset_paths

    align = item.data[:align]
    title = item.data[:title]
    count = item.data[:count]
    elements = []
    shrink_jobs = []
    # `image:` = toujours "image" (pleine page par défaut) ; `tab:` =
    # toujours notation générée ; `score:` = notation SI vectoriel, image SI
    # matriciel (photo/scan d'une partition).
    if !asset_paths.is_a?(Array)
      elements << Layout.build_image_element(pdf, asset_paths, x0, width, align: align, title: title, count: count)
      shrink_jobs << { local_index: 0, svg_paths: asset_paths, align: align, title: title } if item.data[:shrink] == "true"
    else
      # UN élément de pagination PAR SYSTÈME : "chaque système doit être un élément
      # indépendant" — 2 systèmes peuvent tenir sur une page, le suivant passer sur la
      # page d'après. Titre seulement sur le 1er système, repère "x N" (`count:`)
      # seulement sur le dernier.
      asset_paths.each_with_index do |svg_path, i|
        sys_title = i.zero? ? title : nil
        sys_count = i == asset_paths.size - 1 ? count : nil
        el = Layout.build_tabla_element_v2(pdf, [svg_path], x0, width, align: align, title: sys_title, count: sys_count, scale: tab_scale)
        # Gouttière resserrée SEULEMENT entre 2 systèmes de LA MÊME tablature (jamais
        # celle qui précède le 1er, qui reste la gouttière normale — voir MIN/MAX_V_DIST
        # `:tabla_system` : "systèmes trop séparés").
        el.gutter_type = :tabla_system if i.positive?
        elements << el
        shrink_jobs << { local_index: i, svg_paths: [svg_path], align: align, title: sys_title } if item.data[:shrink] == "true"
      end
    end
    [elements, shrink_jobs]
  end

  # Empile verticalement des éléments déjà construits (ex. plusieurs systèmes d'une
  # même tablature dans UNE colonne d'un `:side_by_side`) en UN seul élément — chacun
  # garde son `x` propre (déjà fixé à sa construction), seul `y` est décalé ici.
  def self.stack_elements_vertically(elements, gutter)
    return elements.first if elements.size <= 1

    height = elements.sum(&:height) + gutter * (elements.size - 1)
    draw = lambda do |pdf_, y|
      cursor = y
      elements.each do |el|
        el.draw.call(pdf_, cursor)
        cursor += el.height + gutter
      end
    end
    Layout::PageElement.new(height, draw)
  end

  # Largeur RÉELLEMENT dessinée d'une ressource à cette largeur dispo (jamais une
  # tranche arbitraire) — une image occupe toute la largeur donnée (comportement déjà
  # établi de `build_image_element`, "pleine page par défaut").
  def self.resource_natural_width(item, folder, width, tab_scale)
    asset_paths = notation_asset_paths(item, folder, width)
    return width unless asset_paths.is_a?(Array)

    Layout.svg_embed_width(File.read(asset_paths.first), width, scale: tab_scale)
  end

  # Une colonne (`:resource` ou `:lyrics`) -> son élément, dessiné à `x` EXACT (aucun
  # gutter ajouté en interne ici — géré une seule fois par l'appelant, entre les deux
  # colonnes).
  def self.side_by_side_column_element(pdf, col, folder, x, width, h_gutter, chord_ascent, text_ascent, text_descent, tab_scale)
    if col[:kind] == :resource
      els, = build_resource_page_elements(pdf, col[:item], folder, x, width, tab_scale)
      stack_elements_vertically(els, h_gutter)
    elsif col[:block]
      Layout.build_text_column_element(pdf, col[:block], x, width, chord_ascent, text_ascent, text_descent)
    end
  end

  # Côte à côte (`//`, issue "Le Sud") — le cas réel documenté (Manuel/song/gabarit.adoc,
  # "tablature en vis-à-vis du premier couplet") est TOUJOURS 2 colonnes : la 1re prend
  # SA largeur naturelle (celle d'une tablature courte, pas une moitié de page arbitraire
  # — sinon le texte se retrouve inutilement loin, "pas aligné"), la 2e comble le reste,
  # juste après une seule gouttière.
  def self.build_side_by_side_element(pdf, item, folder, x0, width, h_gutter, chord_ascent, text_ascent, text_descent, tab_scale)
    columns = item.data[:columns]
    return nil if columns.empty?

    if columns.size == 2
      col1, col2 = columns
      w1 = col1[:kind] == :resource ? resource_natural_width(col1[:item], folder, width, tab_scale) : (col1[:block] ? [Layout.block_width(pdf, col1[:block]), width].min : 0)
      el1 = side_by_side_column_element(pdf, col1, folder, x0, w1, h_gutter, chord_ascent, text_ascent, text_descent, tab_scale)
      x2 = x0 + w1 + h_gutter
      el2 = side_by_side_column_element(pdf, col2, folder, x2, [width - w1 - h_gutter, 0].max, h_gutter, chord_ascent, text_ascent, text_descent, tab_scale)
      sub_elements = [el1, el2].compact
    else
      # Plus de 2 colonnes (rare, hors du cas documenté) : partage égal, pas de
      # calibrage fin par contenu.
      n = columns.size
      col_w = (width - h_gutter * (n - 1)) / n.to_f
      x = x0
      sub_elements = columns.map do |c|
        el = side_by_side_column_element(pdf, c, folder, x, col_w, h_gutter, chord_ascent, text_ascent, text_descent, tab_scale)
        x += col_w + h_gutter
        el
      end.compact
    end
    return nil if sub_elements.empty?

    height = sub_elements.map(&:height).max
    draw = lambda { |pdf_, y| sub_elements.each { |el| el.draw.call(pdf_, y) } }
    Layout::PageElement.new(height, draw)
  end

  def self.build_song_elements(pdf, items, rows, folder, text_x, text_w, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent)
    row_idx = 0
    elements = []
    shrink_jobs = [] # {index:, svg_paths:, align:, title:} — tablas à réduire si besoin
    tab_scale = notation_scale(items, folder, text_w)
    items.each do |item|
      case item.type
      when :row
        elements.concat(Layout.build_row_or_split(pdf, rows[row_idx], text_x, text_w, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent))
        row_idx += 1
      when :side_by_side
        el = build_side_by_side_element(pdf, item, folder, text_x, text_w, h_gutter, chord_ascent, text_ascent, text_descent, tab_scale)
        elements << el if el
      when :tabla, :score, :image
        base_index = elements.size
        els, sjs = build_resource_page_elements(pdf, item, folder, text_x, text_w, tab_scale)
        elements.concat(els)
        sjs.each { |sj| shrink_jobs << sj.merge(index: base_index + sj[:local_index]).except(:local_index) }
      end
    end
    [elements, shrink_jobs]
  end

  # Paires [accord, case] d'une chanson SEULES (`ChordDiagrams.collect_chord_frets`),
  # transposition appliquée comme en production réelle (`build`) — scan LÉGER pour
  # `missing diags` (CLI) : aucun PDF généré, juste `.lyr`/`.infos` lus.
  def self.chord_frets_for_song(folder)
    lyr_path = FileFinder.find(folder, :lyr)
    return [] unless lyr_path

    infos_path = FileFinder.find(folder, :inf)
    meta = infos_path ? parse_infos(infos_path) : {}
    lyr_blocks, = parse_lyr(lyr_path)
    if meta["transpose"]
      decalage_lettres, decalage_demitons = Transpose.parser_entete(meta["transpose"])
      ChordDiagrams.transpose_blocks!(lyr_blocks, decalage_lettres, decalage_demitons)
    end
    ChordDiagrams.collect_chord_frets(lyr_blocks.values)
  end

  # Orchestrateur .gab/.lyr/.infos : un dossier = une chanson + une mise en page. `.gab`
  # OPTIONNEL (voir `default_items`). page_count/first_page_no : voir `build_from_dsl`.
  # `layout:` (Hash title_band:/diags_position:/lyrics_flux:, voir `CarnetBuilder::LAYOUTS`
  # et Manuel/song/layout.adoc) : défauts du CARNET pour cette chanson — un `.gab` explicite
  # garde priorité (une chanson peut toujours s'écarter du layout général, Manuel : "on
  # peut le faire chanson par chanson ou de façon générale... ou les deux").
  def self.build(folder, out_path, page_size_in:, page_count:, first_page_no: 1, layout_preset: {}, debug_marks: false, carnet_folder: nil, infos_overrides: {}, override_infos_path: nil,
      paper: PrinterProfile::DEFAULT_PAPER, bleed: PrinterProfile::DEFAULT_BLEED, facing_pages: PrinterProfile::DEFAULT_FACING_PAGES,
      outside_margin: nil, gutter_margin: nil, top_margin: nil, bot_margin: nil, left_margin: nil, right_margin: nil)
    DiagsSync.sync!(folder)
    gab_path = FileFinder.find(folder, :gab)
    # `.gab` vide (0 octet ou blanc) : traité comme absent, jamais une page blanche
    # imprimée pour un fichier sans contenu , "Amstrong" — bon sens).
    gab_path = nil if gab_path && File.read(gab_path).strip.empty?
    lyr_path = FileFinder.find(folder, :lyr)
    infos_path = FileFinder.find(folder, :inf)
    raise "fichiers .lyr/.lyrics ou .infos/.inf introuvables dans #{folder}" unless lyr_path && infos_path

    # Cascade complète, n'importe quelle clé : défaut app < .infos du carnet < .infos de
    # la chanson < .infos indexé de cette entrée du .tdm (`infos_overrides`,
    # `CarnetBuilder.resolve_infos_override`).
    carnet_infos_path = carnet_folder && FileFinder.find(carnet_folder, :inf)
    carnet_meta = carnet_infos_path ? parse_infos(carnet_infos_path) : {}
    meta = carnet_meta.merge(parse_infos(infos_path)).merge(infos_overrides)
    # Fixé ICI, AVANT tout ce qui peut lever un conflit (`Options.load!`) — sinon ce
    # conflit reste étiqueté avec l'identité de la
    # chanson PRÉCÉDENTE (`Layout.current_song`/`current_page` pas encore mis à jour),
    # bug constaté sur `diags_size` (Angie créditée d'un réglage venant de Blackbird).
    Layout.current_song = meta["title"] || File.basename(folder)
    Layout.current_page = first_page_no
    Options.load!(meta: meta, infos_path: infos_path, carnet_folder: carnet_folder, override_path: override_infos_path, layout_preset: layout_preset)
    # `Tablator.active_preset` est un état GLOBAL du module ,
    # config "regular-tablatures"/"mini-tablatures", `tools/tablator/presets.rb`) —
    # TOUJOURS fixé ici, explicitement, jamais laissé hériter d'une chanson précédente
    # construite dans le MÊME process (même bug de principe que `Layout.building_log_path`,
    # 2026-08-25 : sans ce reset, une chanson sans `tabs_preset:` reprendrait par erreur
    # le preset de la précédente).
    Tablator.active_preset = Options.get(:tabs_preset)
    lyr_blocks, lyr_order = parse_lyr(lyr_path)
    if meta["transpose"]
      decalage_lettres, decalage_demitons = Transpose.parser_entete(meta["transpose"])
      ChordDiagrams.transpose_blocks!(lyr_blocks, decalage_lettres, decalage_demitons)
      Layout.log_build("transposition \"#{meta["transpose"]}\" appliquée (#{decalage_lettres} lettre(s)/#{decalage_demitons} demi-ton(s))")
    end
    title_band_default = Options.get(:title_band)
    diag_position_default = Options.get(:diags_position)
    diag_align_default = Options.get(:diags_align)
    lyrics_flux = Options.get(:lyrics_flux).to_sym
    Layout.log_build("layout résolu : title_band=#{title_band_default} diag_position=#{diag_position_default} lyrics_flux=#{lyrics_flux}")
    if gab_path
      Layout.log_build(".gab trouvé (#{gab_path}) : mise en page explicite, layout du carnet ignoré pour l'agencement")
      items = parse_gab(gab_path)
      referenced = items.flat_map { |i|
        next i.data[:names] if i.type == :row
        next i.data[:columns].select { |c| c[:kind] == :lyrics }.flat_map { |c| c[:names] } if i.type == :side_by_side

        []
      }.flat_map { |n| n.split("+") }.to_set
      lyr_order.uniq.reject { |name| referenced.include?(name) }.each do |name|
        Layout.conflict!("bloc \"#{name}\" du .lyr non mentionné dans le .gab", solution: "ajouté en fin de chanson")
        items << GabItem.new(:row, { names: [name], directives: {} })
      end
    else
      Layout.log_build("agencement auto (default_items, RAO5 pairage par type)")
      items = default_items(lyr_blocks, lyr_order, title_band: title_band_default, diag_position: diag_position_default, diag_align: diag_align_default, lyrics_flux: lyrics_flux)
    end
    page_size = page_size_in.map { |v| v * 72 }
    page_w_pt, page_h_pt = page_size
    # Réglages imprimeur reçus de l'appelant (carnet entier), jamais relus depuis `meta`.
    printer = PrinterProfile.new(page_count: page_count, trim_width: page_size_in[0], trim_height: page_size_in[1],
      paper: paper, bleed: bleed, facing_pages: facing_pages, outside_margin: outside_margin, gutter_margin: gutter_margin,
      top_margin: top_margin, bot_margin: bot_margin, left_margin: left_margin, right_margin: right_margin)

    Prawn::Document.generate(out_path, page_size: page_size, margin: 0) do |pdf|
      Layout.register_fonts(pdf)
      Layout.apply_print_margins(pdf, printer, first_page_no, page_w_pt, page_h_pt, debug_marks: debug_marks)
      # `diag_position`/`dynamic_mode` calculés ICI, AVANT l'entête (issue #69) : le
      # numéro de capo se place naturellement en haut à gauche, SAUF si une colonne de
      # diags y est déjà (alors à droite) — il faut donc savoir où vont les diags avant
      # de dessiner l'entête, pas après.
      diag_item_data = items.find { |i| i.type == :diags }&.data
      diag_position = (diag_item_data&.dig(:position) || diag_position_default).to_s.downcase.to_sym
      diag_align = (diag_item_data&.dig(:align) || diag_align_default).to_s.downcase.to_sym
      # `int`/`ext` (Manuel/song/layout.adoc, "Int"/"Ext" — côté reliure/extérieur) : PAS
      # résolu à une seule valeur left/right ici — le côté reliure change de page en page
      # (recto/verso) DANS une même chanson (bug constaté 2026-08-24, "À bicyclette" p.4/
      # p.5 : reliure à droite sur l'une, à gauche sur l'autre, une seule chanson peut
      # couvrir les deux — "on s'en branle d'où commence la chanson"). Les deux
      # variantes gauche/droite sont construites ICI (`text_x`/`text_x_r`, `side_col`/
      # `side_col_r`), `Layout.paginate_and_draw` choisit la bonne PAGE PAR PAGE.
      dynamic_mode = %i[int ext].include?(diag_position) ? diag_position : nil
      # Capo (issue #69) : par défaut à DROITE, alignée avec le bandeau — sauf si la
      # colonne de diags occupe elle-même la droite de la PREMIÈRE page de la chanson
      # (`first_page_no`, même résolution recto/verso que `want_left_for` dans
      # `Layout.paginate_and_draw`), auquel cas la capo passe à gauche.
      diag_col_side_p1 = if dynamic_mode
        left_here = !printer.facing_pages || (dynamic_mode == :int) == printer.recto?(first_page_no)
        left_here ? :left : :right
      elsif diag_position == :left
        :left
      elsif diag_position == :right
        :right
      end
      capo_side = diag_col_side_p1 == :right ? :left : :right

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
      header_bottom = header_style == :band ? Layout.draw_header_band(pdf, meta, capo_side: capo_side) : Layout.draw_header_inline(pdf, meta, capo_side: capo_side)
      Layout.log_build("titre en #{header_style == :band ? "bandeau" : "ligne simple"} (header_style)")

      chord_frets = ChordDiagrams.collect_chord_frets(lyr_blocks.values)
      diag_paths = chord_frets.filter_map { |chord, fret| ChordDiagrams.diag_path(chord, fret: fret, carnet_dir: carnet_folder, song_dir: folder) }
      Layout.log_build("#{diag_paths.size} diagramme(s) d'accord, position=#{dynamic_mode ? "#{dynamic_mode} (résolu page par page)" : diag_position}")

      text_x, text_w, first_avail_h, side_col, row_excess, row_excess_w = Layout.layout_diags(pdf, diag_paths, dynamic_mode ? :left : diag_position, header_bottom, align: diag_align)
      text_x_r, side_col_r = if dynamic_mode
        tx_r, _, _, sc_r, = Layout.layout_diags(pdf, diag_paths, :right, header_bottom, align: diag_align)
        [tx_r, sc_r]
      end

      chord_ascent = Layout.font_metric(pdf, Layout.scaled_chord_size) { pdf.font.ascender }
      text_ascent = Layout.font_metric(pdf, Options.get(:font_size)) { pdf.font.ascender }
      text_descent = Layout.font_metric(pdf, Options.get(:font_size)) { pdf.font.descender }

      bare_kind_counters = Hash.new(0)
      rows = items.select { |i| i.type == :row }.map { |i| i.data[:names].map { |name| with_intro_align(resolve_block(lyr_blocks, name, lyr_order, bare_kind_counters, row_directives: i.data[:directives]), name) } }
      # `:side_by_side` (issue "Le Sud", `//` mêlant une marque tab/score/image et des
      # paroles) : chaque colonne `:lyrics` résolue en `Block` directement dans la
      # colonne (`c[:block]`) — pas besoin d'indexation parallèle comme `rows`, chaque
      # colonne ne sert qu'à SON item.
      items.select { |i| i.type == :side_by_side }.each do |item|
        item.data[:columns].each do |c|
          next unless c[:kind] == :lyrics

          name = c[:names].first
          c[:block] = name ? with_intro_align(resolve_block(lyr_blocks, name, lyr_order, bare_kind_counters, row_directives: c[:directives]), name) : nil
        end
      end
      col1_w, col2_w, h_gutter = Layout.row_column_widths(pdf, rows, text_w)

      elements, shrink_jobs = build_song_elements(pdf, items, rows, folder, text_x, text_w, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent)
      elements_r = dynamic_mode ? build_song_elements(pdf, items, rows, folder, text_x_r, text_w, col1_w, col2_w, h_gutter, chord_ascent, text_ascent, text_descent).first : nil

      # `shrink` : RESPECTE la position choisie par l'auteur du .gab — jamais déplacée par
      # la pagination (épinglée), seulement réduite si besoin. L'espace qui lui revient
      # est calculé avec sa hauteur NATURELLE (pas simulée à 0 : sinon la pagination des
      # AUTRES éléments se trompe aussi, en pensant qu'il y a plus de place libre qu'il
      # n'y en aura réellement — vu en pratique, ça faisait remonter la page suivante sur
      # celle-ci). Ainsi la page d'à côté ne peut jamais déborder sur celle-ci
      # .
      pinned = shrink_jobs.map { |j| j[:index] }
      shrink_jobs.each do |job|
        pages = Layout.paginate(elements, first_avail_h, pdf.bounds.height, pinned: pinned)
        page = pages.find { |p| (p[:start]...p[:finish]).cover?(job[:index]) }
        others_h = (page[:start]...page[:finish]).sum { |j| j == job[:index] ? 0 : elements[j].height }
        max_h = page[:avail_h] - others_h
        next if elements[job[:index]].height <= max_h

        Layout.log_build("tabla \"#{job[:title] || job[:svg_paths]}\" (shrink: true) réduite à #{max_h.round(1)}pt de haut pour tenir sur sa page")
        elements[job[:index]] = Layout.build_tabla_element_v2(
          pdf, job[:svg_paths], text_x, text_w, align: job[:align], title: job[:title], max_height: max_h
        )
        elements_r[job[:index]] = Layout.build_tabla_element_v2(
          pdf, job[:svg_paths], text_x_r, text_w, align: job[:align], title: job[:title], max_height: max_h
        ) if dynamic_mode
      end

      Layout.paginate_and_draw(pdf, elements, first_avail_h, printer: printer, page_w_pt: page_w_pt, page_h_pt: page_h_pt, first_page_no: first_page_no, pinned: pinned, side_col: side_col, text_x: text_x, text_w: text_w, debug_marks: debug_marks,
        dynamic_mode: dynamic_mode, elements_alt: elements_r, side_col_alt: side_col_r, text_x_alt: text_x_r, row_excess: row_excess, row_excess_w: row_excess_w)
    end
  end

  # Chemin legacy : chanson en un seul fichier `.dsl` (frontmatter YAML + blocs), voir
  # `DSLParser`. page_size_in : [largeur, hauteur] en pouces. header_style: :inline (titre +
  # infos sur la ligne du titre, fond page) ou :band (bandeau foncé pleine page en haut,
  # texte clair). page_count: nombre de pages TOTAL du carnet (détermine la marge de
  # reliure, cf. `PrinterProfile#gutter_margin`) ; first_page_no: numéro de la première page de
  # cette chanson dans le carnet complet (recto/verso, numérotation).
  def self.build_from_dsl(dsl_path, out_path, page_size_in:, page_count:, header_style: :inline, first_page_no: 1, debug_marks: false)
    song = DSLParser.parse(File.read(dsl_path))
    chord_frets = ChordDiagrams.collect_chord_frets(song.blocks)
    page_size = page_size_in.map { |v| v * 72 }
    page_w_pt, page_h_pt = page_size
    printer = PrinterProfile.new(page_count: page_count, trim_width: page_size_in[0], trim_height: page_size_in[1],
      paper: PrinterProfile::DEFAULT_PAPER, bleed: PrinterProfile::DEFAULT_BLEED)

    Prawn::Document.generate(out_path, page_size: page_size, margin: 0) do |pdf|
      Layout.register_fonts(pdf)
      Layout.apply_print_margins(pdf, printer, first_page_no, page_w_pt, page_h_pt, debug_marks: debug_marks)
      header_bottom = header_style == :band ? Layout.draw_header_band(pdf, song.meta) : Layout.draw_header_inline(pdf, song.meta)

      diag_paths = chord_frets.filter_map { |chord, fret| ChordDiagrams.diag_path(chord, fret: fret) }
      diag_w = Layout::DIAG_W
      diag_heights = diag_paths.map { |p| Layout.svg_height_for(File.read(p), diag_w) }

      # Essai 1 : page recto — "intérieur" (côté reliure) = gauche.
      diag_col_w = diag_w + Layout::DIAG_TEXT_GAP
      text_x = diag_col_w
      text_w = pdf.bounds.width - diag_col_w

      Layout.draw_diags(pdf, diag_paths, diag_heights, x: 0, avail_h: header_bottom, width: diag_w)

      chord_ascent = Layout.font_metric(pdf, Layout.scaled_chord_size) { pdf.font.ascender }
      text_ascent = Layout.font_metric(pdf, Options.get(:font_size)) { pdf.font.ascender }
      text_descent = Layout.font_metric(pdf, Options.get(:font_size)) { pdf.font.descender }
      cote_a_cote = song.meta.fetch("cote_a_cote", true)

      elements = Layout.build_row_elements(pdf, song.blocks, text_x, text_w, chord_ascent, text_ascent, text_descent, cote_a_cote)
      tabla_el = Layout.build_tabla_element(pdf, song.meta, dsl_path, text_x, text_w)
      elements << tabla_el if tabla_el

      Layout.paginate_and_draw(pdf, elements, header_bottom, printer: printer, page_w_pt: page_w_pt, page_h_pt: page_h_pt, first_page_no: first_page_no, debug_marks: debug_marks)
    end
  end
end
