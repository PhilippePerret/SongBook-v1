require "prawn"
require "combine_pdf"
require "fileutils"
require_relative "page_builder"
require_relative "layout"
require_relative "kdp"
require_relative "cover_builder"
require_relative "markdown_page"
require_relative "locale"
require_relative "song_cache"
require_relative "app_options"
require_relative "file_finder"

# Construit un carnet ENTIER : pages de garde/TOC/textes de front matter (selon le
# `.infos`/`.inf` du carnet), une page par chanson réelle du `.tdm` (via `PageBuilder.build`),
# colophon, assemblage. Le nombre de pages n'est plus une cible imposée (Phil,
# 2026-08-20 : "24, c'était juste pour KDP") — il sort de la somme réelle de ce qui est
# effectivement rendu. Aucun Ruby dans le dossier du carnet (app grand public) : `.tdm`/`.toc`
# (liste des chansons) + `.infos`/`.inf` (config, clé/valeur imbriquée par indentation —
# PAS du YAML, parseur maison ci-dessous, Phil 2026-08-20). Root-name libre pour les deux
# (voir `FileFinder`), jamais un nom de fichier imposé.
module CarnetBuilder
  # Layouts nommés standards (Manuel/song/layout.adoc) — pas encore finalisés (Phil,
  # 2026-08-20 : "le but sera de fixer les caractéristiques"), axes pour l'instant :
  # bandeau ou pas (title_band), position des diagrammes (diag_position), enchaînement
  # des strophes (lyrics_flux), alignement du bloc "intro" (intro_align). `diags_size`/
  # `music_position` (Manuel/song/layout.adoc) pas encore implémentés. `diag_position:
  # both` (Column/Column-B) pas encore implémenté — voir `Layout.layout_diags`, lève une
  # erreur claire si sélectionné.
  # Un fichier YAML par layout sous `assets/layouts/` (nom de fichier = nom du layout,
  # ex. `regular-B.yaml`) — ajouter/modifier un layout ne touche jamais aux autres.
  # `_default.yaml` : valeurs par défaut, jamais un layout nommé lui-même — chaque layout
  # part de ces valeurs et n'a besoin de définir que ses écarts (Phil, 2026-08-21).
  LAYOUTS_DIR = File.expand_path("../assets/layouts", __dir__)

  def self.load_layout_yaml(path)
    (YAML.safe_load_file(path, symbolize_names: false) || {}).each_with_object({}) do |(k, v), layout|
      layout[k.to_sym] = v.is_a?(String) ? v.to_sym : v
    end
  end

  DEFAULT_LAYOUT = load_layout_yaml(File.join(LAYOUTS_DIR, "_default.yaml")).freeze

  LAYOUTS = Dir.glob(File.join(LAYOUTS_DIR, "*.yaml")).each_with_object({}) do |path, h|
    name = File.basename(path, ".yaml")
    next if name == "_default"

    h[name] = DEFAULT_LAYOUT.merge(load_layout_yaml(path))
  end.freeze

  # Layout customisé (chanson ou carnet) : `.lay`/`.layout` (voir `FileFinder`), même
  # parseur maison que le `.infos` du carnet (clé/valeur, PAS du YAML). Ne définit que les
  # écarts au layout de base — fusionné PAR-DESSUS lui, jamais un remplacement complet.
  def self.find_layout_file(dir)
    FileFinder.find(dir, :lay)
  end

  def self.load_layout_override(path)
    parse_nested_infos(path).each_with_object({}) { |(k, v), h| h[k.to_sym] = v.is_a?(String) ? v.to_sym : v }
  end

  # Cascade complète (Phil, 2026-08-21) : `_default.yaml` -> layout nommé du `.infos`/`.inf`
  # du carnet (`layout:`, SI DÉFINI) -> `.lay`/`.layout` du carnet (SI DÉFINI) -> `.lay`/`.layout` de
  # la chanson (SI DÉFINI). Chaque étage écrase seulement les clés qu'il définit.
  def self.resolve_song_layout(song_folder, carnet_layout)
    path = find_layout_file(song_folder)
    path ? carnet_layout.merge(load_layout_override(path)) : carnet_layout
  end

  TOC_LABELS = { song: "par chanson", performer: "par interprète", composer: "par compositeur", author: "par parolier" }.freeze

  # `.infos`/`.inf` du carnet : clé/valeur, imbrication par INDENTATION (comme le `.infos` des
  # chansons, mais récursif) — pas du YAML, jamais passé à Psych (Phil, 2026-08-20).
  # `clé:` seule (valeur vide) ouvre un bloc enfant (les lignes plus indentées suivantes) ;
  # `true`/`false` convertis en booléen, tout le reste reste une chaîne brute (aucune règle
  # de caractère réservé, contrairement à YAML — ex. `@2026...` passe tel quel).
  # ` # commentaire` (espace avant le #) retiré de la ligne avant parsing.
  def self.parse_nested_infos(path)
    root = {}
    stack = [[-1, root]]
    File.readlines(path).each do |raw|
      content = raw.chomp.sub(/\s+#.*\z/, "")
      next if content.strip.empty?

      indent = content[/\A */].size
      key, value = content.strip.split(":", 2)
      next unless key

      key = key.strip
      value = value.to_s.strip

      stack.pop while stack.last[0] >= indent
      parent = stack.last[1]

      if value.empty?
        child = {}
        parent[key] = child
        stack.push([indent, child])
      else
        parent[key] = value == "true" ? true : (value == "false" ? false : value)
      end
    end
    root
  end

  # Gabarit d'une chanson auto-créée (Phil, 2026-08-20) : jamais un .tdm sans dossier
  # silencieusement ignoré, jamais de placeholder muet — une VRAIE chanson à compléter.
  SONG_TEMPLATE = <<~LYR
    {couplet-1}
    Ici le premier couplet

    {refrain-1}
    Le refrain de la chanson
  LYR

  ID_RE = /\A[a-z0-9]+(-[a-z0-9]+)*\z/
  YEAR_RE = /-((?:1[6-9]|20)\d{2})\z/

  def self.slugify(title)
    title.downcase
      .gsub(/[àâä]/, "a").gsub(/[éèêë]/, "e").gsub(/[îï]/, "i").gsub(/[ôö]/, "o").gsub(/[ùûü]/, "u").gsub("ç", "c")
      .gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  # "a-bicyclette-montand-1968" -> ["A Bicyclette Montand", "1968"] : retire l'année finale
  # si présente, éclate le reste sur les tirets, capitalise chaque mot.
  def self.derive_title_and_year_from_id(id)
    year = id[YEAR_RE, 1]
    base = year ? id.sub(/-#{year}\z/, "") : id
    title = base.split("-").map { |w| w.sub(/\A./) { |c| c.upcase } }.join(" ")
    [title, year]
  end

  # Chanson listée dans le .tdm mais introuvable (cache + disque, voir `SongCache`) :
  # créée, jamais écartée (Phil, 2026-08-20 : "si cette chanson a été décidée, elle a été
  # décidée"). `name` en forme d'id (kebab-case) -> titre dérivé (+ année si présente en
  # fin d'id) ; sinon `name` EST le titre -> id dérivé par slugification. Renvoie
  # `{folder:, infos:}` (forme attendue par le bloc de `SongCache.resolve`).
  def self.create_song_folder(chansons_dir, name)
    if name.match?(ID_RE)
      id = name
      title, year = derive_title_and_year_from_id(id)
    else
      title = name
      id = slugify(title)
      year = nil
    end

    folder = File.join(chansons_dir, title)
    Dir.mkdir(folder) unless Dir.exist?(folder)

    infos = { "id" => id }
    PageBuilder::INFOS_CANONICAL_KEYS.each { |k| infos[k] = "" }
    infos["title"] = title
    infos["year"] = year if year
    File.write(File.join(folder, "c.infos"), "#{infos.map { |k, v| "#{k}: #{v}" }.join("\n")}\n")
    File.write(File.join(folder, "c.lyr"), SONG_TEMPLATE)

    Layout.conflict!("chanson \"#{name}\" absente de Chansons/", solution: "dossier \"#{title}\" créé automatiquement (gabarit vide à compléter)")
    { folder: title, infos: infos }
  end

  # {nom du .tdm => entrée SongCache (folder:/infos:)} pour chaque chanson — dossier créé
  # à la volée si absent et `build_unknown_song` (racine du `.infos`/`.inf` du carnet, défaut app
  # `true`) ; entrée `nil` seulement si `build_unknown_song: false` ET chanson introuvable
  # (alors ignorée, comme avant).
  def self.resolve_song_folders(chansons_dir, songs, build_unknown_song)
    songs.map do |name|
      entry = SongCache.resolve(chansons_dir, name) do |missing_name|
        create_song_folder(chansons_dir, missing_name) if build_unknown_song
      end
      [name, entry]
    end
  end

  def self.carnet_folder?(dir)
    !!FileFinder.find(dir, :tdm)
  end

  def self.song_folder?(dir)
    !!FileFinder.find(dir, :lyr)
  end

  # Chanson seule, HORS carnet : format/layout de `_default.yaml` (pas de `.tdm`/`.infos`
  # de carnet à consulter). Passe 1 (mesure, page_count provisoire) -> passe 2 (page_count
  # réel), même principe que `build` pour la marge de reliure KDP.
  def self.build_song(song_folder)
    layout = DEFAULT_LAYOUT
    page_size_in = layout.fetch(:format).to_s.split(/\s*x\s*/i).map { |v| AppOptions.length_pt(v) / AppOptions::IN_TO_PT }
    slug = slugify(File.basename(song_folder))
    export_dir = File.join(song_folder, "export")
    FileUtils.mkdir_p(export_dir)

    tmp_out = File.join(export_dir, ".tmp-#{slug}.pdf")
    PageBuilder.build(song_folder, tmp_out, page_size_in: page_size_in, page_count: 24, first_page_no: 1, layout: layout)
    page_count = [CombinePDF.load(tmp_out).pages.size, 24].max
    File.delete(tmp_out)

    out_path = File.join(export_dir, "#{slug}.pdf")
    PageBuilder.build(song_folder, out_path, page_size_in: page_size_in, page_count: page_count, first_page_no: 1, layout: layout)
    out_path
  end

  def self.build(carnet_folder, only_song: nil, cover: false, debug_marks: false)
    tdm_path = FileFinder.find(carnet_folder, :tdm)
    raise "aucun fichier .tdm/.toc trouvé dans #{carnet_folder}" unless tdm_path

    infos_path = FileFinder.find(carnet_folder, :inf)
    raise "aucun fichier .infos/.inf trouvé dans #{carnet_folder}" unless infos_path

    conf = parse_nested_infos(infos_path)
    title = conf.fetch("title")
    subtitle = conf["subtitle"]
    build_unknown_song = conf.fetch("build_unknown_song", AppOptions.get("build_unknown_song"))
    # `format` (trim size KDP) : convention historique en POUCES pour un nombre SANS unité
    # ("8.27 x 6" -> inches, comme le format papier KDP est toujours exprimé) — jamais en
    # points comme le reste de `AppOptions.length_pt` (bug constaté 2026-08-21 : "8.27"
    # lu comme 8.27pt, marges KDP en inches soustraites d'une largeur de page presque
    # nulle, `pdf.bounds.width` négatif, crash Prawn `CannotFit`). Une unité explicite
    # ("21cm x 15cm") reste convertie normalement.
    page_size_in = conf.fetch("format") { AppOptions.get("format") }.split(/\s*x\s*/i).map { |v| v =~ /[a-z]/i ? AppOptions.length_pt(v) / AppOptions::IN_TO_PT : v.to_f }
    page_size_pt = page_size_in.map { |v| v * AppOptions::IN_TO_PT }
    layout_name = conf["layout"]
    base_layout = layout_name ? LAYOUTS.fetch(layout_name) { raise "layout inconnu : #{layout_name} (voir CarnetBuilder::LAYOUTS)" } : DEFAULT_LAYOUT
    carnet_layout_path = find_layout_file(carnet_folder)
    carnet_layout = carnet_layout_path ? base_layout.merge(load_layout_override(carnet_layout_path)) : base_layout
    fm = conf.fetch("front_matter", {})
    toc_conf = fm.fetch("table_of_contents", {})
    tdm_position = toc_conf.fetch("position", AppOptions.get("tdm_position"))

    chansons_dir = File.expand_path("../../Chansons", carnet_folder)
    export_dir = File.join(carnet_folder, "export")
    # Carnet entier -> export/songbooks/ ; chanson isolée (only_song) -> export/songs/
    # (Phil, 2026-08-21).
    songbooks_dir = File.join(export_dir, "songbooks")
    songs_dir = File.join(export_dir, "songs")
    logs_dir = File.join(export_dir, "xlogs")
    cover_dir = File.join(export_dir, "cover")
    FileUtils.mkdir_p(songbooks_dir)
    FileUtils.mkdir_p(songs_dir)
    FileUtils.mkdir_p(logs_dir)
    FileUtils.mkdir_p(cover_dir)
    songs = File.readlines(tdm_path).map { |l| l.sub(/\A-\s*/, "").strip }.reject(&:empty?)

    existing_versions = Dir.glob(File.join(songbooks_dir, "*-v*.pdf")).filter_map { |f| f[/-v(\d+)\.pdf\z/, 1]&.to_i }
    version = (existing_versions.max || 0) + 1
    slug = File.basename(carnet_folder).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    out_path = File.join(songbooks_dir, "#{slug}-v#{version}.pdf")
    # Logs dans export/logs/ (Phil, 2026-08-21 : revient sur "à côté du PDF").
    log_dir = logs_dir
    log_stem = only_song ? "#{slug}-song-#{slugify(only_song)}" : "#{slug}-v#{version}"
    Layout.conflict_log_path = File.join(log_dir, "#{log_stem}-conflicts.log")
    File.write(Layout.conflict_log_path, "Début : #{Time.now}\n")
    Layout.building_log_path = File.join(log_dir, "#{log_stem}-building.log")
    File.write(Layout.building_log_path, "Début : #{Time.now}\n")

    page_w_pt, page_h_pt = page_size_pt

    # --- 1) Résolution des dossiers (par nom de dossier, id ou title — jamais seulement
    # un nom littéral) — chanson du .tdm sans dossier : créée (gabarit vide), JAMAIS
    # écartée (Phil, 2026-08-20 : "si cette chanson a été décidée, elle a été décidée").
    # Compte de pages provisoire pour la passe de mesure SEULEMENT : la marge de reliure
    # KDP a besoin d'un total, pas encore connu tant que les chansons ne sont pas rendues
    # — reset avec le total EXACT en passe 2.
    song_entries = resolve_song_folders(chansons_dir, songs, build_unknown_song)
    real_songs = song_entries.select { |_, entry| entry }
    provisional_page_count = [real_songs.size * 2 + 10, 24].max

    real_page_counts = {}
    real_songs.each do |name, entry|
      folder = File.join(chansons_dir, entry[:folder])
      tmp_out = File.join(export_dir, ".tmp-#{name}.pdf")
      PageBuilder.build(folder, tmp_out, page_size_in: page_size_in, page_count: provisional_page_count, first_page_no: 1, layout: resolve_song_layout(folder, carnet_layout))
      real_page_counts[name] = CombinePDF.load(tmp_out).pages.size
      File.delete(tmp_out)
    end

    # --- 2) Structure du front matter (ordre = ordre des clés dans le `.infos`/`.inf` du carnet) —
    # `tdm_position` (options.yaml, surchargeable par le `.infos`/`.inf` du carnet) décide si la TDM
    # rejoint le front matter ("front", avant tout texte) ou reste à la fin ("end", défaut
    # app, voir 4bis). Sections .md : EXACTEMENT une page pour l'instant (limitation connue).
    kdp_probe = KDP.new(page_count: provisional_page_count, trim_width: page_size_in[0], trim_height: page_size_in[1], paper: :white, bleed: false)
    content_h_pt = page_h_pt - Layout.in_pt(kdp_probe.top_margin) - Layout.in_pt(kdp_probe.bottom_margin)
    # Comptage des rows par TdM AVANT le rendu des chansons (les numéros de page ne sont
    # pas encore connus) — mais `performer:`/`composer:`/`lyrics:` viennent du `.infos`,
    # déjà chargés dans `real_songs`, donc le REGROUPEMENT (et donc le nombre de rows,
    # song + un header par groupe, voir `grouped_toc_rows`) peut être calculé ici, en
    # amont, avec les mêmes valeurs qu'au rendu final (page: nil, jamais utilisé pour
    # compter).
    prelim_entries = real_songs.map do |name, entry|
      meta = entry[:infos]
      { name: meta["title"] || name, performer: meta["performer"].to_s, performer_name: meta["performer_name"].to_s,
        composer: meta["composer"].to_s, lyrics: meta["lyrics"].to_s, first_page: nil, last_page: nil }
    end
    toc_page_list = toc_specs(toc_conf, prelim_entries, content_h_pt)
    front_specs = front_matter_specs(fm, conf["copyright"], tdm_position == "front" ? toc_page_list : [])
    front_matter_page_count = front_specs.size

    # --- 3) Rendu final des chansons, dans l'ordre du TDM, page par page RÉELLE -------
    entries = [] # {name:, interprete:, compositeur:, parolier:, first_page:, last_page:}
    combined_songs = CombinePDF.new
    page_no = front_matter_page_count + 1

    real_songs.each do |name, entry|
      folder = File.join(chansons_dir, entry[:folder])
      meta = entry[:infos]
      if only_song == name || only_song == entry[:folder]
        # `only_song` : ISOLE une seule chanson, rendue avec EXACTEMENT les mêmes
        # paramètres (page_count, first_page_no, layout résolu) que dans ce carnet réel —
        # même appel `PageBuilder.build`, pas une simulation à part (Phil, 2026-08-21 :
        # "sortir la chanson EXACTEMENT comme elle sortirait"). Sortie PERSISTANTE, jamais
        # un temp supprimé — numérotée en version (Phil, 2026-08-23), même convention que
        # les carnets complets (`existing_versions`/`version` plus haut), sinon un second
        # essai écrase silencieusement le précédent.
        song_stem = "#{slug}-song-#{slugify(name)}"
        song_existing_versions = Dir.glob(File.join(songs_dir, "#{song_stem}-v*.pdf")).filter_map { |f| f[/-v(\d+)\.pdf\z/, 1]&.to_i }
        song_version = (song_existing_versions.max || 0) + 1
        song_out = File.join(songs_dir, "#{song_stem}-v#{song_version}.pdf")
        PageBuilder.build(folder, song_out, page_size_in: page_size_in, page_count: provisional_page_count, first_page_no: page_no, layout: resolve_song_layout(folder, carnet_layout), debug_marks: debug_marks)
        return song_out
      end

      tmp_out = File.join(export_dir, ".tmp-#{name}.pdf")
      PageBuilder.build(folder, tmp_out, page_size_in: page_size_in, page_count: provisional_page_count, first_page_no: page_no, layout: resolve_song_layout(folder, carnet_layout))
      n = real_page_counts[name]
      combined_songs << CombinePDF.load(tmp_out)
      File.delete(tmp_out)
      entries << { name: meta["title"] || name, performer: meta["performer"].to_s, performer_name: meta["performer_name"].to_s,
                   composer: meta["composer"].to_s, lyrics: meta["lyrics"].to_s, first_page: page_no, last_page: page_no + n - 1 }
      page_no += n
    end
    raise "chanson introuvable pour only_song: #{only_song.inspect} (voir .tdm : #{tdm_path})" if only_song

    last_song_page = page_no - 1

    # --- 3bis) TDM "end" (tdm_position) : juste avant le colophon. Parité (1p -> belle-
    # page, 2p -> fausse-page, >2p -> toujours belle-page) forcée via une page blanche si
    # besoin. "front" : déjà dans `front_specs` (voir 2), rien à refaire ici.
    toc_at_end = tdm_position != "front"
    end_toc_list = toc_at_end ? toc_page_list : []
    toc_start = force_parity(last_song_page + 1, toc_parity(end_toc_list.size))
    needs_blank_before_toc = toc_start != last_song_page + 1
    toc_end = toc_start + end_toc_list.size - 1

    colophon_page_no = toc_end + 1
    # La page de crédits est TOUJOURS une belle-page (recto, numéro IMPAIR — Phil,
    # 2026-08-20) : une page blanche est insérée avant si elle tomberait sur une page paire.
    needs_blank_before_colophon = colophon_page_no.even?
    colophon_page_no += 1 if needs_blank_before_colophon
    total_page_count = colophon_page_no
    # Le total EXACT est maintenant connu — les marges KDP ci-dessus (chansons, passe 1+2)
    # ont été calculées sur `provisional_page_count` : écart possible seulement si ça
    # change de palier de marge KDP (rare sur un carnet-test), pas re-rendu pour l'instant.
    kdp_final = KDP.new(page_count: total_page_count, trim_width: page_size_in[0], trim_height: page_size_in[1], paper: :white, bleed: false)

    render_blank_page = lambda do |blank_page_no|
      blank_out = File.join(export_dir, ".tmp-blank-#{blank_page_no}.pdf")
      Prawn::Document.generate(blank_out, page_size: [page_w_pt, page_h_pt], margin: 0) do |pdf|
        Layout.register_fonts(pdf)
        Layout.apply_kdp_margins(pdf, kdp_final, blank_page_no, page_w_pt, page_h_pt)
        Layout.current_song = "(carnet)"
        Layout.current_page = blank_page_no
        Layout.log_build("page blanche insérée (RATDM12)")
      end
      loaded = CombinePDF.load(blank_out)
      File.delete(blank_out)
      loaded
    end

    combined_songs << render_blank_page.call(last_song_page + 1) if needs_blank_before_toc

    # --- 4) Front matter (garde/faux-titre/textes), avec les VRAIES pages connues ------
    front_out = File.join(export_dir, ".tmp-front.pdf")
    Prawn::Document.generate(front_out, page_size: [page_w_pt, page_h_pt], margin: 0) do |pdf|
      Layout.register_fonts(pdf)
      front_specs.each_with_index do |spec, i|
        page_no = i + 1
        pdf.start_new_page if i.positive?
        Layout.apply_kdp_margins(pdf, kdp_final, page_no, page_w_pt, page_h_pt)
        Layout.current_song = "(carnet)"
        Layout.current_page = page_no
        Layout.log_build("front matter (#{spec[:kind]}) rendu (RATDM12)")
        draw_front_matter_page(pdf, spec, title, subtitle, entries, carnet_folder)
      end
    end

    # --- 4bis) TDM "end" seulement (voir 3bis — "front" déjà rendue dans front_out) -----
    toc_combined = nil
    unless end_toc_list.empty?
      toc_out = File.join(export_dir, ".tmp-toc.pdf")
      Prawn::Document.generate(toc_out, page_size: [page_w_pt, page_h_pt], margin: 0) do |pdf|
        Layout.register_fonts(pdf)
        end_toc_list.each_with_index do |spec, i|
          page_no = toc_start + i
          pdf.start_new_page if i.positive?
          Layout.apply_kdp_margins(pdf, kdp_final, page_no, page_w_pt, page_h_pt)
          Layout.current_song = "(carnet)"
          Layout.current_page = page_no
          Layout.log_build("TdM #{spec[:sort]} (page #{spec[:page] + 1}/#{spec[:pages]}) rendue (RATDM10/RATDM12)")
          draw_front_matter_page(pdf, spec, title, subtitle, entries, carnet_folder)
        end
      end
      toc_combined = CombinePDF.load(toc_out)
      File.delete(toc_out)
    end

    blank_before_colophon = render_blank_page.call(colophon_page_no - 1) if needs_blank_before_colophon

    # --- 5) Colophon (dernière page) : crédits SEULEMENT — le copyright est en page
    # liminaire (voir 4), rien à voir avec les crédits (Phil, 2026-08-20).
    colophon_out = File.join(export_dir, ".tmp-colophon.pdf")
    Prawn::Document.generate(colophon_out, page_size: [page_w_pt, page_h_pt], margin: 0) do |pdf|
      Layout.register_fonts(pdf)
      Layout.apply_kdp_margins(pdf, kdp_final, colophon_page_no, page_w_pt, page_h_pt)
      Layout.current_song = "(carnet)"
      Layout.current_page = colophon_page_no
      Layout.log_build("colophon rendu (RATDM12)")
      draw_credits(pdf, conf.fetch("credits", {}))
    end

    # --- 6) Assemblage final ----------------------------------------------------------
    combined = CombinePDF.load(front_out) << combined_songs
    combined << toc_combined if toc_combined
    combined << blank_before_colophon if blank_before_colophon
    combined << CombinePDF.load(colophon_out)
    File.delete(front_out)
    File.delete(colophon_out)

    SongCache.save(chansons_dir)
    Layout.report_conflicts!
    combined.save(out_path)

    if cover
      cover_out = File.join(cover_dir, "#{slug}-v#{version}-cover.pdf")
      cov_path = File.expand_path("../assets/cover/_default.cov", __dir__)
      CoverBuilder.build(cover_out, cov_path: cov_path, kdp: kdp_final, conf: conf,
        entries: entries, carnet_folder: carnet_folder, debug_marks: debug_marks)
    end

    missing_chords_summary = Layout.missing_chords_summary
    File.open(Layout.conflict_log_path, "a") { |f| f.puts missing_chords_summary } if missing_chords_summary
    File.open(Layout.conflict_log_path, "a") { |f| f.puts "Fin : #{Time.now}" }
    File.open(Layout.building_log_path, "a") { |f| f.puts "Fin : #{Time.now}" }

    puts "#{File.basename(out_path)} généré : #{total_page_count} pages"
    puts "#{File.basename(cover_out)} généré" if cover
    out_path
  end

  # Ordre = ordre des clés dans le `.infos`/`.inf` du carnet (half_title_page, pages_garde,
  # table_of_contents, forword, preface, acknowledgments) — pas une convention éditoriale
  # décidée ici, juste l'ordre que Phil a lui-même écrit dans le fichier. Exception :
  # `copyright` (racine du fichier, pas dans `front_matter`) — n'a RIEN à voir avec les
  # crédits/colophon (Phil, 2026-08-20). Convention imprimerie : mention légale sur la
  # fausse-page, en regard de la page de titre — insérée juste après la 1re page-titre
  # (`half_title`/`garde`, la première présente), pas dans `front_matter_specs` par un
  # réglage dédié puisque le `.infos`/`.inf` du carnet n'en a pas.
  # Réserve pour le titre "Table des matières — ..." — la 1re ligne de TOC ne doit JAMAIS
  # partager la même zone que ce titre (bug constaté v14 : la 1re entrée écrasait le
  # titre, gouttières calculées sur la pleine hauteur de page).
  TOC_HEADING_RESERVE = 40.0

  # Taille de police PAR SORT (Phil, 2026-08-23) :
  # - :performer -> 8,5pt fixe (réduite depuis 11pt par essais successifs).
  # - :song -> 10pt, SAUF si ça dépasse 2 pages à 10pt (`toc_paginate` à 10pt, pour de
  #   vrai, pas une estimation) : dans ce cas 9pt, jamais moins.
  # - toutes les autres (:composer/:author) -> 11pt, jamais touchées.
  def self.toc_font_size(sort, entries, content_h_pt)
    case sort
    when :performer
      8.5
    when :song
      rows = toc_rows(entries, sort)
      pages_at_10 = toc_paginate(rows, content_h_pt, toc_row_h(10)).size
      pages_at_10 > 2 ? 9 : 10
    else
      11
    end
  end

  # Hauteur RÉELLE d'une ligne à `size` (même police/taille que `draw_toc_2col`) — mesurée
  # sur un `Prawn::Document` jetable, JAMAIS une valeur approchée en dur (bug constaté
  # 2026-08-23 : une TdM calculée pile à sa capacité, avec une hauteur de ligne approchée,
  # débordait de quelques points au rendu réel — une row entière tombait DANS LA MARGE,
  # invisible — interdit, rien ne doit jamais y être posé). Police enregistrée identique à
  # celle du rendu (`Layout.register_fonts`) : la mesure est EXACTE, pas approchée — le
  # rendu (`draw_toc_2col`) mesure la même valeur sur son propre `pdf`, forcément identique
  # (même police, même taille), planification et rendu ne peuvent plus se désaccorder.
  def self.toc_row_h(size)
    probe = Prawn::Document.new
    Layout.register_fonts(probe)
    Layout.font_metric(probe, size) { probe.font.height }
  end

  # RATDM6 : 1/2 ligne vide au-dessus de chaque bloc interprète, sauf le 1er de la colonne
  # (Phil, 2026-08-23, essai) — MÊME valeur que `header_gap_factor` dans `draw_toc_2col`
  # (sinon la capacité calculée ici ne correspond plus à ce que `draw_toc_2col` dessine
  # réellement, et des rows débordent hors page, invisibles : bug constaté 2026-08-23,
  # TdM par interprète incomplète — le compte de pages ignorait le coût des en-têtes de
  # groupe).
  TOC_HEADER_GAP_FACTOR = 0.5

  # `rows` (sous-liste, page candidate) tient-il sur UNE page de TOC ? Simule EXACTEMENT le
  # split 2-colonnes de `draw_toc_2col` (même `half`, mêmes `chunks` jamais coupés).
  def self.toc_fits?(rows, avail_lines)
    return true if rows.empty?

    chunks = toc_chunks(rows)
    half = (rows.size / 2.0).ceil
    col1 = []
    count = 0
    chunks.each do |chunk|
      break if col1.any? && count >= half

      col1 << chunk
      count += chunk.size
    end
    col2 = chunks[col1.size..] || []
    content_lines = lambda do |cs|
      cs.each_with_index.sum { |c, i| c.size + (i.positive? && c.first[:kind] == :header ? TOC_HEADER_GAP_FACTOR : 0) }
    end
    content_lines.call(col1) <= avail_lines && content_lines.call(col2) <= avail_lines
  end

  # Étale `rows` sur autant de pages qu'il faut, chaque page recevant le PLUS GRAND préfixe
  # (en blocs entiers, RATDM7) qui tient réellement (`toc_fits?`) — jamais un compte de
  # pages approché sur le nombre brut de rows (bug v14/2026-08-23, voir `toc_fits?`).
  # Renvoie `[[rows page 1], [rows page 2], ...]`.
  def self.toc_paginate(rows, content_h_pt, row_h)
    avail_lines = [(content_h_pt - TOC_HEADING_RESERVE) / row_h, 1.0].max
    chunks = toc_chunks(rows)
    pages = []
    remaining = chunks
    until remaining.empty?
      lo = 1
      hi = remaining.size
      best = 1
      while lo <= hi
        mid = (lo + hi) / 2
        if toc_fits?(remaining[0...mid].flatten, avail_lines)
          best = mid
          lo = mid + 1
        else
          hi = mid - 1
        end
      end
      pages << remaining[0...best].flatten
      remaining = remaining[best..] || []
    end
    pages
  end

  # `toc_specs_list` : non vide seulement si `tdm_position: front` — insérée AVANT tout
  # texte (avant-propos/préface/remerciements), après garde/copyright (Phil, 2026-08-20 :
  # "elle se place avant tout texte, donc avant une préface").
  def self.front_matter_specs(fm, copyright, toc_specs_list)
    specs = []
    specs << { kind: :half_title } if fm["half_title_page"]
    specs << { kind: :garde } if fm["pages_garde"]
    if copyright
      idx = specs.index { |s| %i[half_title garde].include?(s[:kind]) }
      specs.insert(idx ? idx + 1 : 0, { kind: :copyright, text: normalize_copyright(copyright) })
    end

    specs.concat(toc_specs_list)

    specs << { kind: :markdown, file: fm["forword"], heading: "Avant-propos" } if fm["forword"]
    specs << { kind: :markdown, file: fm["preface"], heading: "Préface" } if fm["preface"]
    specs << { kind: :markdown, file: fm["acknowledgments"], heading: "Remerciements" } if fm["acknowledgments"]
    specs
  end

  # TOC en configuration par défaut : PAS dans le front matter, à la fin, juste avant le
  # colophon (Phil, 2026-08-20). Étalée sur autant de pages qu'il faut (voir
  # `toc_paginate`) — jamais coupée/chevauchée.
  # `toc_pages` calculé PAR SORT via `toc_paginate` (pas un compte approché sur
  # `song_count`/nombre brut de rows, bug constaté : la TdM par interprète/compositeur/
  # parolier a PLUS de rows qu'il n'y a de chansons — un `:header` par groupe en plus de
  # chaque `:song`, voir `grouped_toc_rows` — ET chaque en-tête de groupe coûte 1,5 ligne
  # de plus que son rang ne le laisse penser (RATDM6) — un compte approché sur le nombre
  # brut de rows faisait déborder silencieusement ces vues, rows tronquées).
  def self.toc_specs(toc_conf, entries, content_h_pt)
    specs = []
    { song: "per_song", performer: "per_performer", composer: "per_composer", author: "per_author" }.each do |sort, key|
      next unless toc_conf[key]

      size = toc_font_size(sort, entries, content_h_pt)
      toc_pages = toc_paginate(toc_rows(entries, sort), content_h_pt, toc_row_h(size)).size
      toc_pages = [toc_pages, 1].max
      toc_pages.times { |i| specs << { kind: :toc, sort: sort, page: i, pages: toc_pages, font_size: size } }
    end
    specs
  end

  # Règle de parité de la TDM (Phil, 2026-08-20) : 1 page -> belle-page (impaire) ;
  # 2 pages -> fausse-page (paire) ; plus de 2 pages -> toujours belle-page (impaire).
  def self.toc_parity(page_count)
    return nil if page_count.zero?
    return :odd if page_count == 1
    return :even if page_count == 2

    :odd
  end

  # Avance `page_no` d'une page si sa parité ne correspond pas à `want` (:odd/:even) —
  # `nil` = peu importe. Renvoie le nouveau numéro (identique si déjà bon).
  def self.force_parity(page_no, want)
    return page_no if want.nil? || (want == :odd) == page_no.odd?

    page_no + 1
  end

  def self.draw_front_matter_page(pdf, spec, title, subtitle, entries, carnet_folder)
    case spec[:kind]
    when :half_title
      draw_centered_text_box(pdf, title, y: pdf.bounds.height / 2 + 10, size: 18, style: :bold)
    when :garde
      # Titre centré, éventuellement l'auteur du livre en dessous (Phil, 2026-08-20) —
      # aucun texte de substitution. RAT3 : sous-titre ajouté en dessous s'il existe.
      draw_centered_text_box(pdf, title, y: pdf.bounds.height / 2 + 10, size: 18, style: :bold)
      if subtitle
        Layout.log_build("page de garde : sous-titre \"#{subtitle}\" ajouté sous le titre (RAT3)")
        draw_centered_text_box(pdf, subtitle, y: pdf.bounds.height / 2 + 10 - 26, size: 13)
      end
    when :copyright
      # "en bas de page" (Phil, 2026-08-20) — PAS centré verticalement comme le reste du
      # front matter, une simple mention en pied de fausse-page.
      draw_centered_text_box(pdf, spec[:text], y: 40, size: 9)
    when :toc
      # " (suite)" sur les pages 2+ d'une même TdM (Phil, 2026-08-23) — remplace la
      # décision précédente "jamais de (1/2)/(2/2)" par cette forme-là.
      suite = spec[:page].positive? ? " (suite)" : ""
      draw_heading(pdf, "Table des matières #{TOC_LABELS.fetch(spec[:sort])}#{suite}")
      # Même pagination qu'à la planification (`toc_specs`) — structure des rows identique
      # (mêmes chansons/groupes), donc mêmes coupures de page, seul `pdf.bounds.height`
      # remplace le `content_h_pt` calculé hors contexte Prawn (valeurs égales en pratique).
      # `font_size` DÉCIDÉ à la planification (`toc_specs`), jamais redécidé ici — stocké
      # dans `spec`, sinon un second calcul pourrait diverger du premier (même bug de
      # fond que l'ancien désaccord planification/rendu). `row_h` mesuré sur CE `pdf` réel
      # (même police/taille, voir `toc_row_h`) : exactement la même valeur.
      row_h = Layout.font_metric(pdf, spec[:font_size]) { pdf.font.height }
      rows = toc_paginate(toc_rows(entries, spec[:sort]), pdf.bounds.height, row_h)[spec[:page]] || []
      draw_toc_2col(pdf, rows, top: pdf.bounds.height - TOC_HEADING_RESERVE, sort: spec[:sort], size: spec[:font_size])
    when :markdown
      md_path = File.join(carnet_folder, spec[:file])
      unless File.exist?(md_path)
        Layout.conflict!("fichier Markdown introuvable : #{spec[:file]}", solution: "section #{spec[:heading]} vide")
        return
      end
      draw_heading(pdf, spec[:heading])
      MarkdownPage.render(pdf, md_path, pdf.bounds.width, top: pdf.bounds.height - 40)
    end
  end

  # `text_box` centré horizontalement, ancré en HAUT à `y` — passe par `Layout.engrave`
  # (Phil, 2026-08-20 : plus aucune gravure directe hors de ce garde-fou).
  def self.draw_centered_text_box(pdf, text, y:, size:, style: nil)
    opts = { width: pdf.bounds.width, size: size }
    h = pdf.height_of(text, **opts)
    Layout.engrave(bottom: y - h, context: "texte \"#{text[0, 20]}\"") do
      pdf.text_box text, at: [0, y], align: :center, style: style, **opts
    end
  end

  # Titre de section (TOC/Markdown) en haut de page, taille fixe — passe par `Layout.engrave`.
  def self.draw_heading(pdf, text)
    y = pdf.bounds.height - 20
    descent = Layout.font_metric(pdf, 14) { pdf.font.descender }
    Layout.engrave(bottom: y - descent, context: "titre de section") { pdf.draw_text text, at: [0, y], size: 14, style: :bold }
  end

  # `sort` :song garde l'ordre du TDM (une ligne par chanson) ; :performer/:composer/
  # :author regroupent par le champ correspondant (performer/composer/lyrics), un en-tête
  # par valeur du champ (triées alphabétiquement) suivi des chansons de ce groupe en
  # retrait — chansons au champ vide : pas d'en-tête, en fin de liste (Phil, 2026-08-21).
  # Chaque ligne : {kind: :header/:song, label:, page: (nil pour :header), indent:}.
  def self.toc_rows(entries, sort)
    case sort
    when :song
      entries.map { |e| { kind: :song, label: e[:name], page: e[:first_page].to_s, indent: false } }
    when :performer
      grouped_toc_rows(entries, :performer)
    when :composer
      grouped_toc_rows(entries, :composer)
    when :author
      grouped_toc_rows(entries, :lyrics)
    end
  end

  # RATDM11.1/11.2 (performers seulement) : classement sur `performer_name` s'il est
  # défini (.infos), sinon sur le NOM (dernier mot de `performer`, pas le prénom) —
  # l'affichage (en-tête) garde toujours `performer` en entier, seul le TRI change.
  # Articles ("the"/"le"/"les"/"la") en tête retirés du classement.
  TOC_SORT_ARTICLES_RE = /\A(the|les|le|la)\s+/i

  def self.toc_sort_key(entry)
    if entry[:performer_name].to_s.empty?
      base = entry[:performer].to_s.split.last.to_s
    else
      base = entry[:performer_name]
      Layout.log_build("TdM performer \"#{entry[:performer]}\" : tri sur performer_name=\"#{base}\" (RATDM11.1)")
    end
    stripped = base.sub(TOC_SORT_ARTICLES_RE, "")
    Layout.log_build("TdM performer \"#{base}\" : article de tête retiré pour le tri -> \"#{stripped}\" (RATDM11.2)") if stripped != base
    stripped
  end

  def self.grouped_toc_rows(entries, field)
    named, unnamed = entries.partition { |e| !e[field].empty? }
    sort_key = field == :performer ? ->(group_first) { toc_sort_key(group_first) } : ->(group_first) { group_first[field] }
    Layout.log_build("TdM #{field} : #{named.map { |e| e[field] }.uniq.size} groupe(s), #{unnamed.size} chanson(s) au champ vide (RATDM5)")
    rows = []
    named.group_by { |e| e[field] }.sort_by { |name, group| sort_key.call(group.first) }.each do |name, group|
      rows << { kind: :header, label: name, page: nil, indent: false }
      group.each { |e| rows << { kind: :song, label: e[:name], page: e[:first_page].to_s, indent: true } }
    end
    unnamed.each { |e| rows << { kind: :song, label: e[:name], page: e[:first_page].to_s, indent: false } }
    rows
  end

  # "@2026..." -> "©2026..." : Phil a mis un `@` volontairement (test), le signe correct
  # est ©. Normalisé au rendu plutôt que dans le fichier — INTERDICTION d'y toucher
  # (Phil, 2026-08-20).
  def self.normalize_copyright(text)
    text.sub(/\A@/, "©")
  end

  # Colophon (dernière page) : crédits SEULEMENT — qui a travaillé sur le livre, rôle
  # localisé via `Locale` (dossier `Locales/<lang>/loc.yaml`).
  def self.draw_credits(pdf, credits)
    lines = credits.map { |role, name| "#{Loc.get(role)} : #{name}" }
    y = 60 + (lines.size - 1) * 16
    lines.each do |line|
      draw_centered_text_box(pdf, line, y: y, size: 10)
      y -= 16
    end
  end

  # RATDM1 (2 colonnes) + RATDM2 (même nombre de lignes de chaque côté si la table ne
  # remplit pas 2 colonnes pleines) + RATDM3 (chiffre placé à `plus long titre + MIN_H_DIST
  # [:tdm_num]`, la même position dans les deux colonnes) + RATDM4 (filet de conduite entre
  # titre et chiffre) + RATDM6 (ligne vide au-dessus de chaque bloc interprète, sauf le 1er
  # de chaque colonne) + RATDM7 (jamais un bloc interprète coupé entre 2 colonnes) + RATDM8
  # (gouttière+marge généreuses -> filets plus longs) + RATDM9 (TdM courte en hauteur ->
  # séparée de son titre, sans être centrée). `rows` = [{kind:, label:, page:, indent:}, ...]
  # (voir `toc_rows`) — un `:header` (nom de groupe, gras, sans numéro/filet) n'est jamais
  # indenté ; un `:song` indenté (`TOC_INDENT_W`) appartient au groupe au-dessus.
  TOC_INDENT_W = 14.0

  # RATDM7 : un groupe = un `:header` + les `:song` indentés qui suivent immédiatement ;
  # toute autre ligne (`:song` non indenté — tri `:song`, ou entrée au champ vide) est son
  # propre groupe d'1 ligne. Un groupe ne sera jamais coupé entre 2 colonnes.
  def self.toc_chunks(rows)
    chunks = []
    rows.each do |row|
      if row[:indent] && chunks.last&.first&.dig(:kind) == :header
        chunks.last << row
      else
        chunks << [row]
      end
    end
    chunks
  end

  def self.draw_toc_2col(pdf, rows, top: pdf.bounds.height, sort: :song, size:)
    # Interligne "1" d'un traitement de texte = la hauteur naturelle d'une ligne à cette
    # taille, sans rien ajouter — PAS l'équilibrage habituel (`distribute_v_gutters`), qui
    # étirait les entrées sur toute la hauteur de page dispo (bug constaté, Phil 2026-08-20).
    row_h = Layout.font_metric(pdf, size) { pdf.font.height }

    chunks = toc_chunks(rows)
    half = (rows.size / 2.0).ceil
    col1_chunks = []
    count = 0
    chunks.each do |chunk|
      break if col1_chunks.any? && count >= half

      col1_chunks << chunk
      count += chunk.size
    end
    col2_chunks = chunks[col1_chunks.size..] || []
    Layout.log_build("TdM #{sort} : #{rows.size} ligne(s) réparties en #{chunks.size} bloc(s) (RATDM7), #{col1_chunks.sum(&:size)}/#{col2_chunks.sum(&:size)} lignes col1/col2 (RATDM1/2)")

    # RATDM6 : 1/2 ligne vide au-dessus de CHAQUE bloc interprète, sauf le 1er de la
    # colonne (Phil, 2026-08-23, essai — valeur partagée avec `toc_fits?`/
    # `TOC_HEADER_GAP_FACTOR`, sinon désaccord pagination/rendu).
    # À L'INTÉRIEUR d'un bloc (header -> ses chansons, ou chanson -> chanson suivante du
    # même bloc), toujours 1 ligne pleine, jamais touché.
    header_gap_factor = TOC_HEADER_GAP_FACTOR
    col_lines = lambda do |chunks_|
      chunks_.each_with_index.sum { |chunk, i| chunk.size + (i.positive? && chunk.first[:kind] == :header ? header_gap_factor : 0) }
    end
    content_lines = [col_lines.call(col1_chunks), col_lines.call(col2_chunks)].max

    # RATDM9.1 (Phil, 2026-08-21, valeur provisoire) : TdM courte en hauteur -> interligne
    # 1,5 — SEULEMENT pour la TdM par chanson (`sort: :song`) : Phil, 2026-08-21, "l'autre
    # [la TdM par interprète] ne sera jamais courte". Décidé sur l'interligne "1" de base,
    # AVANT tout étirement, pour ne pas se rebalancer soi-même hors de la zone "courte".
    short = sort == :song && (content_lines * row_h) < top
    effective_row_h = short ? row_h * 1.5 : row_h
    Layout.log_build("TdM #{sort} courte en hauteur : interligne passé à 1,5 (RATDM9.1)") if short
    content_h = content_lines * effective_row_h

    # RATDM9.2 (Phil, 2026-08-21, valeur provisoire — "sans la mettre au milieu" : un tiers
    # de la place libre, pas la moitié) : TdM courte en hauteur -> séparée de son titre par
    # un espace, jamais glued dessous ni centrée dans la page.
    slack = [top - content_h, 0].max
    top -= slack / 3.0
    Layout.log_build("TdM #{sort} courte : décalée de #{(slack / 3.0).round(1)}pt sous son titre (RATDM9.2)") if slack.positive?

    label_w = ->(row) { pdf.width_of(row[:label], size: size, style: row[:kind] == :header ? :bold : nil) + (row[:indent] ? TOC_INDENT_W : 0) }
    max_title_w = rows.map(&label_w).max || 0
    num_x_offset = max_title_w + Layout.min_h_dist(:tdm_num)
    num_w = rows.filter_map { |row| row[:page] }.map { |pno| pdf.width_of(pno, size: size) }.max || 0
    natural_col_w = num_x_offset + num_w
    # La gouttière ne doit JAMAIS être plus mince que la marge (bloc <-> bord de page) —
    # sinon un excès de place de chaque côté produit une gouttière ridiculement fine avec
    # de grandes marges vides (Phil, 2026-08-21). À l'équilibre marge = gouttière, les deux
    # valent slack/3 (page = marge + colonne + gouttière + colonne + marge) — le clamp de
    # `distribute_gutter` peut retomber sous cette valeur quand il y a beaucoup de place ;
    # `equal_thirds` est alors le plancher réel.
    gutter_for = lambda do |col_w|
      hslack = [pdf.bounds.width - col_w * 2, 0].max
      [Layout.distribute_gutter(pdf.bounds.width, [col_w, col_w]), hslack / 3.0].max
    end
    h_gutter = gutter_for.call(natural_col_w)
    x1 = [(pdf.bounds.width - (natural_col_w * 2 + h_gutter)) / 2.0, 0].max

    # RATDM8 (Phil, 2026-08-21, valeurs provisoires — "> 2cm ?"/"1cm ?") : gouttière+marge
    # déjà généreuses -> on leur emprunte 1cm pour allonger les filets de conduite, plutôt
    # que de le laisser en blanc pur.
    if (h_gutter + x1) > AppOptions::CM_TO_PT * 2
      num_x_offset += AppOptions::CM_TO_PT
      natural_col_w += AppOptions::CM_TO_PT
      h_gutter = gutter_for.call(natural_col_w)
      x1 = [(pdf.bounds.width - (natural_col_w * 2 + h_gutter)) / 2.0, 0].max
      Layout.log_build("TdM #{sort} : gouttière+marge généreuses, filets allongés de 1cm (RATDM8)")
    end
    x2 = x1 + natural_col_w + h_gutter

    leader_char = Layout::TDM[:leader_character]
    leader_space = Layout::TDM[:leader_space]
    leader_char_w = pdf.width_of(leader_char, size: size)

    ascent = Layout.font_metric(pdf, size) { pdf.font.ascender }
    descent = Layout.font_metric(pdf, size) { pdf.font.descender }

    [[col1_chunks, x1], [col2_chunks, x2]].each do |col_chunks, x0|
      y = top - ascent
      col_chunks.each_with_index do |chunk, ci|
        y -= effective_row_h * header_gap_factor if ci.positive? && chunk.first[:kind] == :header # RATDM6
        chunk.each do |row|
          label = row[:label]
          x = x0 + (row[:indent] ? TOC_INDENT_W : 0)
          style = row[:kind] == :header ? :bold : nil
          Layout.engrave(bottom: y - descent, context: "ligne TDM \"#{label}\"") do
            pdf.draw_text label, at: [x, y], size: size, style: style
            if row[:page]
              num_x = x0 + num_x_offset
              leader_start = x + pdf.width_of(label, size: size, style: style) + leader_space
              leader_end = num_x - leader_space
              cx = leader_start
              while cx + leader_char_w <= leader_end
                pdf.draw_text leader_char, at: [cx, y], size: size
                cx += leader_char_w + leader_space
              end
              pdf.draw_text row[:page], at: [num_x, y], size: size
            end
          end
          y -= effective_row_h
        end
      end
    end
  end
end
