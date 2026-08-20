require "prawn"
require "combine_pdf"
require_relative "page_builder"
require_relative "layout"
require_relative "kdp"
require_relative "markdown_page"
require_relative "locale"
require_relative "song_cache"

# Construit un carnet ENTIER : pages de garde/TOC/textes de front matter (selon
# `carnet.infos`), une page par chanson réelle du `.tdm` (via `PageBuilder.build`),
# colophon, assemblage. Le nombre de pages n'est plus une cible imposée (Phil,
# 2026-08-20 : "24, c'était juste pour KDP") — il sort de la somme réelle de ce qui est
# effectivement rendu. Aucun Ruby dans le dossier du carnet (app grand public) : `.tdm`
# (liste des chansons) + `carnet.infos` (config, clé/valeur imbriquée par indentation —
# PAS du YAML, parseur maison ci-dessous, Phil 2026-08-20).
module CarnetBuilder
  # Layouts nommés standards (Manuel/song/layout.adoc) — pas encore finalisés (Phil,
  # 2026-08-20 : "le but sera de fixer les caractéristiques"), 3 axes pour l'instant :
  # bandeau ou pas (header_style), position des diagrammes, empilement des strophes.
  # `:both` (diagrammes des deux côtés, Column/Column-B) pas encore implémenté — voir
  # `Layout.layout_diags`, lève une erreur claire si sélectionné.
  LAYOUTS = {
    "regular-B" => { header_style: :band, diag_position: :left, stacking: :paired },
    "regular" => { header_style: :inline, diag_position: :left, stacking: :paired },
    "column-B" => { header_style: :band, diag_position: :both, stacking: :stacked },
    "column" => { header_style: :inline, diag_position: :both, stacking: :stacked },
  }.freeze

  TOC_LABELS = { song: "par chanson", performer: "par interprète", composer: "par compositeur", author: "par parolier" }.freeze

  # `carnet.infos` : clé/valeur, imbrication par INDENTATION (comme le `.infos` des
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

    infos = { "id" => id, "title" => title }
    infos["year"] = year if year
    File.write(File.join(folder, "c.infos"), "#{infos.map { |k, v| "#{k}: #{v}" }.join("\n")}\n")
    File.write(File.join(folder, "c.lyr"), SONG_TEMPLATE)

    Layout.conflict!("chanson \"#{name}\" absente de Chansons/", solution: "dossier \"#{title}\" créé automatiquement (gabarit vide à compléter)")
    { folder: title, infos: infos }
  end

  # {nom du .tdm => entrée SongCache (folder:/infos:)} pour chaque chanson — dossier créé
  # à la volée si absent et `build_unknown_song` (racine de `carnet.infos`, défaut app
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

  def self.build(carnet_folder)
    tdm_path = Dir.glob(File.join(carnet_folder, "*.*")).find { |f| File.extname(f)[1..].to_s.casecmp?("tdm") }
    raise "aucun fichier .tdm trouvé dans #{carnet_folder}" unless tdm_path

    infos_path = Dir.glob(File.join(carnet_folder, "*.infos")).first
    raise "aucun fichier .infos trouvé dans #{carnet_folder}" unless infos_path

    conf = parse_nested_infos(infos_path)
    title = conf.fetch("title")
    build_unknown_song = conf.fetch("build_unknown_song", true)
    page_size_in = conf.fetch("format").split(/\s*x\s*/i).map(&:to_f)
    layout_name = conf.fetch("layout")
    layout = LAYOUTS.fetch(layout_name) { raise "layout inconnu : #{layout_name} (voir CarnetBuilder::LAYOUTS)" }
    fm = conf.fetch("front_matter", {})
    toc_conf = fm.fetch("table_of_contents", {})

    chansons_dir = File.expand_path("../../Chansons", carnet_folder)
    export_dir = File.join(carnet_folder, "export")
    songs = File.readlines(tdm_path).map { |l| l.sub(/\A-\s*/, "").strip }.reject(&:empty?)

    existing_versions = Dir.glob(File.join(export_dir, "*-v*.pdf")).filter_map { |f| f[/-v(\d+)\.pdf\z/, 1]&.to_i }
    version = (existing_versions.max || 0) + 1
    slug = File.basename(carnet_folder).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    out_path = File.join(export_dir, "#{slug}-v#{version}.pdf")
    Layout.conflict_log_path = File.join(export_dir, "#{slug}-v#{version}-conflicts.log")
    File.write(Layout.conflict_log_path, "Début : #{Time.now}\n")

    page_w_pt, page_h_pt = page_size_in.map { |v| v * 72 }

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
      PageBuilder.build(folder, tmp_out, page_size_in: page_size_in, page_count: provisional_page_count, first_page_no: 1, layout: layout)
      real_page_counts[name] = CombinePDF.load(tmp_out).pages.size
      File.delete(tmp_out)
    end

    # --- 2) Structure du front matter (ordre = ordre des clés dans `carnet.infos`) —
    # chaque section prend EXACTEMENT une page pour l'instant (limitation connue, comme
    # les .md — Phil 2026-08-20).
    front_specs = front_matter_specs(fm, toc_conf, conf["copyright"])
    front_matter_page_count = front_specs.size

    # --- 3) Rendu final des chansons, dans l'ordre du TDM, page par page RÉELLE -------
    entries = [] # {name:, interprete:, compositeur:, parolier:, first_page:, last_page:}
    combined_songs = CombinePDF.new
    page_no = front_matter_page_count + 1

    real_songs.each do |name, entry|
      folder = File.join(chansons_dir, entry[:folder])
      tmp_out = File.join(export_dir, ".tmp-#{name}.pdf")
      meta = entry[:infos]
      PageBuilder.build(folder, tmp_out, page_size_in: page_size_in, page_count: provisional_page_count, first_page_no: page_no, layout: layout)
      n = real_page_counts[name]
      combined_songs << CombinePDF.load(tmp_out)
      File.delete(tmp_out)
      entries << { name: name, interprete: meta["interprete"].to_s, compositeur: meta["compositeur"].to_s,
                   parolier: meta["parolier"].to_s, first_page: page_no, last_page: page_no + n - 1 }
      page_no += n
    end

    last_song_page = page_no - 1
    colophon_page_no = last_song_page + 1
    total_page_count = colophon_page_no
    # Le total EXACT est maintenant connu — les marges KDP ci-dessus (chansons, passe 1+2)
    # ont été calculées sur `provisional_page_count` : écart possible seulement si ça
    # change de palier de marge KDP (rare sur un carnet-test), pas re-rendu pour l'instant.
    kdp_final = KDP.new(page_count: total_page_count, trim_width: page_size_in[0], trim_height: page_size_in[1], paper: :white, bleed: false)

    # --- 4) Front matter (garde/faux-titre/TOC/textes), avec les VRAIES pages connues --
    front_out = File.join(export_dir, ".tmp-front.pdf")
    Prawn::Document.generate(front_out, page_size: [page_w_pt, page_h_pt], margin: 0) do |pdf|
      Layout.register_fonts(pdf)
      front_specs.each_with_index do |spec, i|
        page_no = i + 1
        pdf.start_new_page if i.positive?
        Layout.apply_kdp_margins(pdf, kdp_final, page_no, page_w_pt, page_h_pt)
        Layout.draw_page_number(pdf, kdp_final, page_no, page_w_pt)
        draw_front_matter_page(pdf, spec, title, entries, carnet_folder)
      end
    end

    # --- 5) Colophon (dernière page) : crédits SEULEMENT — le copyright est en page
    # liminaire (voir 4), rien à voir avec les crédits (Phil, 2026-08-20).
    colophon_out = File.join(export_dir, ".tmp-colophon.pdf")
    Prawn::Document.generate(colophon_out, page_size: [page_w_pt, page_h_pt], margin: 0) do |pdf|
      Layout.register_fonts(pdf)
      Layout.apply_kdp_margins(pdf, kdp_final, colophon_page_no, page_w_pt, page_h_pt)
      Layout.draw_page_number(pdf, kdp_final, colophon_page_no, page_w_pt)
      draw_credits(pdf, conf.fetch("credits", {}))
    end

    # --- 6) Assemblage final ----------------------------------------------------------
    combined = CombinePDF.load(front_out) << combined_songs << CombinePDF.load(colophon_out)
    File.delete(front_out)
    File.delete(colophon_out)

    SongCache.save(chansons_dir)
    Layout.report_conflicts!
    combined.save(out_path)
    File.open(Layout.conflict_log_path, "a") { |f| f.puts "Fin : #{Time.now}" }

    puts "#{File.basename(out_path)} généré : #{total_page_count} pages"
    out_path
  end

  # Ordre = ordre des clés dans `carnet.infos` (half_title_page, pages_garde,
  # table_of_contents, forword, preface, acknowledgments) — pas une convention éditoriale
  # décidée ici, juste l'ordre que Phil a lui-même écrit dans le fichier. Exception :
  # `copyright` (racine du fichier, pas dans `front_matter`) — n'a RIEN à voir avec les
  # crédits/colophon (Phil, 2026-08-20). Convention imprimerie : mention légale sur la
  # fausse-page, en regard de la page de titre — insérée juste après la 1re page-titre
  # (`half_title`/`garde`, la première présente), pas dans `front_matter_specs` par un
  # réglage dédié puisque `carnet.infos` n'en a pas.
  def self.front_matter_specs(fm, toc_conf, copyright)
    specs = []
    specs << { kind: :half_title } if fm["half_title_page"]
    specs << { kind: :garde } if fm["pages_garde"]
    if copyright
      idx = specs.index { |s| %i[half_title garde].include?(s[:kind]) }
      specs.insert(idx ? idx + 1 : 0, { kind: :copyright, text: normalize_copyright(copyright) })
    end
    specs << { kind: :toc, sort: :song } if toc_conf["per_song"]
    specs << { kind: :toc, sort: :performer } if toc_conf["per_performer"]
    specs << { kind: :toc, sort: :composer } if toc_conf["per_composer"]
    specs << { kind: :toc, sort: :author } if toc_conf["per_author"]
    specs << { kind: :markdown, file: fm["forword"], heading: "Avant-propos" } if fm["forword"]
    specs << { kind: :markdown, file: fm["preface"], heading: "Préface" } if fm["preface"]
    specs << { kind: :markdown, file: fm["acknowledgments"], heading: "Remerciements" } if fm["acknowledgments"]
    specs
  end

  def self.draw_front_matter_page(pdf, spec, title, entries, carnet_folder)
    case spec[:kind]
    when :half_title
      pdf.text_box title, at: [0, pdf.bounds.height / 2 + 10], width: pdf.bounds.width, align: :center, size: 18, style: :bold
    when :garde
      pdf.text_box "#{title}\n\n(page de garde — mise en page à définir ensemble)",
        at: [0, pdf.bounds.height / 2 + 10], width: pdf.bounds.width, align: :center, size: 14, style: :bold
    when :copyright
      # "en bas de page" (Phil, 2026-08-20) — PAS centré verticalement comme le reste du
      # front matter, une simple mention en pied de fausse-page.
      pdf.text_box spec[:text], at: [0, 40], width: pdf.bounds.width, align: :center, size: 9
    when :toc
      pdf.draw_text "Table des matières — #{TOC_LABELS.fetch(spec[:sort])}", at: [0, pdf.bounds.height - 20], size: 14, style: :bold
      draw_toc_2col(pdf, toc_rows(entries, spec[:sort]))
    when :markdown
      md_path = File.join(carnet_folder, spec[:file])
      unless File.exist?(md_path)
        Layout.conflict!("fichier Markdown introuvable : #{spec[:file]}", solution: "section #{spec[:heading]} vide")
        return
      end
      pdf.draw_text spec[:heading], at: [0, pdf.bounds.height - 20], size: 14, style: :bold
      pdf.bounds = Prawn::Document::BoundingBox.new(pdf, pdf, [pdf.bounds.left, pdf.bounds.height - 40], width: pdf.bounds.width, height: pdf.bounds.height - 40)
      MarkdownPage.render(pdf, md_path, pdf.bounds.width)
    end
  end

  # `sort` :song garde l'ordre du TDM ; :performer/:composer/:author trient alphabétique
  # sur le champ correspondant (interprete/compositeur/parolier), champ vide en fin de liste.
  def self.toc_rows(entries, sort)
    case sort
    when :song
      entries.map { |e| [e[:name], e[:first_page].to_s] }
    when :performer
      sorted_toc_rows(entries, :interprete) { |e| e[:name] }
    when :composer
      sorted_toc_rows(entries, :compositeur) { |e| e[:name] }
    when :author
      sorted_toc_rows(entries, :parolier) { |e| e[:name] }
    end
  end

  def self.sorted_toc_rows(entries, field)
    entries.sort_by { |e| [e[field].empty? ? 1 : 0, e[field]] }.map do |e|
      label = e[field].empty? ? yield(e) : "#{e[field]} — #{yield(e)}"
      [label, e[:first_page].to_s]
    end
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
    lines = credits.map { |role, name| "#{Locale.t(role, default: role)} : #{name}" }
    y = 60 + (lines.size - 1) * 16
    lines.each do |line|
      pdf.text_box line, at: [0, y], width: pdf.bounds.width, size: 10, align: :center
      y -= 16
    end
  end

  # RATDM1 (2 colonnes) + RATDM2 (même nombre de lignes de chaque côté si la table ne
  # remplit pas 2 colonnes pleines) + RATDM3 (chiffre placé à `plus long titre + MIN_H_DIST
  # [:tdm_num]`, la même position dans les deux colonnes) + RATDM4 (filet de conduite entre
  # titre et chiffre). `rows` = [[label, page_no_str], ...].
  def self.draw_toc_2col(pdf, rows)
    size = 11
    row_h = 20.0
    half = (rows.size / 2.0).ceil
    col1 = rows.first(half)
    col2 = rows[half..] || []

    max_title_w = rows.map { |label, _| pdf.width_of(label, size: size) }.max || 0
    num_x_offset = max_title_w + Layout.min_h_dist(:tdm_num)
    num_w = rows.map { |_, pno| pdf.width_of(pno, size: size) }.max || 0
    natural_col_w = num_x_offset + num_w
    h_gutter = Layout.distribute_gutter(pdf.bounds.width, [natural_col_w, natural_col_w])
    block_w = natural_col_w * 2 + h_gutter
    x1 = [(pdf.bounds.width - block_w) / 2.0, 0].max
    x2 = x1 + natural_col_w + h_gutter

    leader_char = Layout::TDM[:leader_character]
    leader_space = Layout::TDM[:leader_space]
    leader_char_w = pdf.width_of(leader_char, size: size)

    max_rows = [col1.size, col2.size].max
    gutters = Layout.distribute_v_gutters(pdf.bounds.height, Array.new(max_rows, row_h))

    [[col1, x1], [col2, x2]].each do |col, x|
      y = pdf.bounds.height - gutters[0]
      col.each_with_index do |(label, pno), i|
        pdf.draw_text label, at: [x, y], size: size
        num_x = x + num_x_offset
        leader_start = x + pdf.width_of(label, size: size) + leader_space
        leader_end = num_x - leader_space
        cx = leader_start
        while cx + leader_char_w <= leader_end
          pdf.draw_text leader_char, at: [cx, y], size: size
          cx += leader_char_w + leader_space
        end
        pdf.draw_text pno, at: [num_x, y], size: size
        y -= row_h + gutters[i + 1]
      end
    end
  end
end
