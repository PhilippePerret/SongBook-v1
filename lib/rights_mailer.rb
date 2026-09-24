# frozen_string_literal: true

require "net/smtp"
require "base64"
require "cgi"
require_relative "rights_manager"
require_relative "publishers_db"
require_relative "carnet_builder"
require_relative "file_finder"
require_relative "app_config"
require_relative "songs_list"
require_relative "mail_config"

# Envoi des demandes de droits (premier contact / relance) à l'éditeur d'une ou
# plusieurs chansons — UN email par éditeur, groupant toutes les chansons du carnet
# dont il détient les droits (Phil, 2026-09-22, plutôt qu'un email par chanson).
# Identifiants SMTP demandés/enregistrés via `MailConfig` (HORS du repo — jamais copiés
# dans un fichier du projet). Envoi réel APRÈS validation explicite de l'appelant
# (`RightsCli`) — ce module n'envoie jamais tout seul, `send_group` est un acte
# délibéré, un par un.
module RightsMailer
  FROM_NAME = "Icare Éditions"
  TEMPLATES_DIR = File.expand_path("../mail_templates", __dir__)

  Group = Struct.new(:publisher_name, :publisher_email, :songs, keyword_init: true)

  # `carnet_folder` -> un `Group` par ÉDITEUR À CONTACTER (pas par chanson) ayant un
  # email renseigné, chacun listant les chansons du carnet concernées
  # (`{title:, infos_path:, status:}`). Une chanson à plusieurs co-éditeurs (Phil,
  # 2026-09-22, "l'éditeur de la chanson doit pouvoir être une liste") apparaît dans
  # PLUSIEURS groupes, un par éditeur — chacun ne reçoit une demande QUE pour les droits
  # qu'il détient réellement. Chansons sans `music_publisher`/email connu ignorées (rien
  # à envoyer).
  #
  # `cf_ipi` (Phil, 2026-09-24) : un éditeur de `PublishersDb` peut renvoyer vers un
  # AUTRE éditeur à qui adresser la demande (sous-édition) — `PublishersDb.resolve_contact`
  # suit cette chaîne jusqu'à l'éditeur effectivement contacté. Plusieurs éditeurs
  # d'origine (A, B, C lui-même) pointant vers le même éditeur final se retrouvent
  # regroupés dans le MÊME `Group` (même email = même clé `by_email`) — une seule
  # demande, toutes leurs œuvres rassemblées.
  #
  # NB : `entry[:infos]` (`SongsList`) vient de `PageBuilder.parse_infos`, un parseur
  # PLAT qui ignore l'indentation (distinct de `CarnetBuilder.parse_nested_infos` — écart
  # pré-existant dans le projet) : `music_publisher:` y remonte éclaté à la racine, donc
  # on relit chaque `.infos` via le parseur imbriqué plutôt que `entry[:infos]`.
  def self.groups_for_carnet(carnet_folder)
    by_email = {}
    SongsList.entries(carnet_folder: carnet_folder).each do |e|
      infos_path = FileFinder.find(File.join(AppConfig.songs_dir, e[:folder]), :inf)
      next unless infos_path

      infos = CarnetBuilder.parse_nested_infos(infos_path)
      RightsManager.publisher_list(infos).each do |publisher|
        _, contact = PublishersDb.resolve_contact(publisher["ipi"])
        contact ||= publisher
        next if contact["email"].to_s.strip.empty?

        email = contact["email"].to_s.strip
        by_email[email] ||= Group.new(publisher_name: contact["name"], publisher_email: email, songs: [])
        by_email[email].songs << {
          title: infos["title"].to_s,
          performer: infos["performer"].to_s,
          composer: infos["composer"].to_s,
          lyrics: infos["lyrics"].to_s,
          iswc: infos["iswc"].to_s,
          infos_path: infos_path,
          status: RightsManager.rights_status(infos),
        }
      end
    end
    by_email.values
  end

  TEMPLATE_FILES = { first_contact: "premier-contact.txt", relance: "relance.txt" }.freeze
  LOGO_PATH = File.join(TEMPLATES_DIR, "logo.jpg")

  # `kind` : `:first_contact` ou `:relance` -> `mail_templates/<fichier>.txt` (texte du
  # mail HORS du code, Phil, 2026-09-22, pour être relu/édité sans toucher au Ruby).
  # Format attendu : bloc `---`/`Subject: ...`/`---` en tête (ou juste `Subject: ...`
  # sur la 1re ligne, sans `---`, les deux formes acceptées), puis le corps avec
  # `{titres}` (liste des chansons du groupe) et `{editeur}` (nom de l'éditeur).
  def self.build_message(group, kind)
    file = TEMPLATE_FILES[kind] or raise ArgumentError, "kind inconnu : #{kind}"
    path = File.join(TEMPLATES_DIR, file)
    raise "modèle de mail introuvable : #{path}" unless File.exist?(path)

    subject, body_lines = split_frontmatter(File.readlines(path, chomp: true))
    body_lines.shift while body_lines.first.to_s.strip.empty?

    titles = group.songs.map { |s| format_song_line(s) }.join("\n")
    body = body_lines.join("\n")
                      .gsub("{titres}", titles)
                      .gsub("{editeur}", group.publisher_name.to_s)

    { subject: subject, body: body }
  end

  # "TITRE (PERFORMER, PAROLIER/COMPOSITEUR, ISWC, s'il existe)" (Phil, 2026-09-22) —
  # compositeur et parolier fusionnés en une seule mention s'ils sont identiques
  # (cas fréquent : même personne aux deux crédits).
  def self.format_song_line(song)
    credit = if song[:composer].to_s.strip.empty? || song[:composer] == song[:lyrics]
               song[:lyrics].to_s.strip
             elsif song[:lyrics].to_s.strip.empty?
               song[:composer].to_s.strip
             else
               "#{song[:composer]} / #{song[:lyrics]}"
             end

    parts = [song[:performer], credit].map(&:to_s).map(&:strip).reject(&:empty?)
    parts << "ISWC #{song[:iswc]}" unless song[:iswc].to_s.strip.empty?

    parts.empty? ? "- #{song[:title]}" : "- #{song[:title]} (#{parts.join(", ")})"
  end

  def self.split_frontmatter(lines)
    if lines.first&.strip == "---"
      close = lines[1..].index { |l| l.strip == "---" }
      frontmatter = close ? lines[1, close] : []
      body = close ? lines[(close + 2)..] : []
    else
      frontmatter = [lines.first]
      body = lines[1..] || []
    end
    subject_line = frontmatter.find { |l| l.to_s.strip.start_with?("Subject:") }
    [subject_line.to_s.sub(/\ASubject:\s*/, "").strip, body]
  end

  # Envoie EFFECTIVEMENT l'email (SMTP réel) puis met à jour `rights_status`/
  # `rights_history` de chaque chanson du groupe. Aucune confirmation ici — c'est
  # `RightsCli` qui valide AVANT d'appeler cette méthode (Phil, 2026-09-22, "envoi
  # automatique APRÈS VALIDATION").
  def self.send_group(group, kind)
    msg = build_message(group, kind)
    deliver(to: group.publisher_email, subject: msg[:subject], html: render_html(msg[:body]))

    event = kind == :first_contact ? "demande envoyée (premier contact)" : "relance envoyée"
    group.songs.each do |s|
      infos = CarnetBuilder.parse_nested_infos(s[:infos_path])
      current = RightsManager.rights_status(infos)
      new_status = kind == :first_contact ? "sent" : current
      RightsManager.append_rights_status(s[:infos_path], new_status, event)
    end
  end

  # `body` (texte brut du template, `{titres}`/`{editeur}` déjà remplacés) -> HTML :
  # échappement d'abord (les titres de chansons peuvent contenir `&`/`<`/`>`), PUIS
  # `**gras**` -> `<strong>`, `{logo}` -> `<img>` (référence `cid:logo`, voir `deliver`),
  # saut de ligne -> `<br>`.
  def self.render_html(body)
    html = CGI.escapeHTML(body)
    html = html.gsub(/\*\*(.+?)\*\*/m, '<strong>\1</strong>')
    html = html.gsub(/\*(.+?)\*/m, '<em>\1</em>')
    html = html.gsub("{logo}", '<img src="cid:logo" alt="Icare Éditions" style="max-width:180px;display:block;margin-top:1em;">')
    html = html.gsub("\n", "<br>\n")
    "<html><body style=\"font-family:sans-serif;font-size:14px;color:#222;\">#{html}</body></html>"
  end

  # `multipart/related` : le HTML + le logo embarqué (`Content-ID: <logo>`, référencé en
  # `cid:logo` dans le HTML — pas un lien externe, l'image reste jointe au mail).
  # Identifiants via `MailConfig.ensure!` (demandés/enregistrés au premier besoin, voir
  # ce module) — `user_name`/`password` pour l'auth SMTP, `from_email` juste comme
  # adresse d'expédition affichée (pas forcément le même compte, voir `MailConfig`).
  def self.deliver(to:, subject:, html:)
    creds = MailConfig.ensure!
    from = creds[:from_email]
    boundary = "----=_songbook_rights_#{rand(1_000_000_000)}"

    parts = +"--#{boundary}\r\n"
    parts << "Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
    parts << "#{html}\r\n\r\n"

    if File.exist?(LOGO_PATH)
      parts << "--#{boundary}\r\n"
      parts << "Content-Type: image/jpeg\r\nContent-Transfer-Encoding: base64\r\n"
      parts << "Content-ID: <logo>\r\nContent-Disposition: inline; filename=\"logo.jpg\"\r\n\r\n"
      parts << "#{Base64.encode64(File.binread(LOGO_PATH))}\r\n"
    end
    parts << "--#{boundary}--\r\n"

    message = <<~MSG
      From: #{encode_header(FROM_NAME)} <#{from}>
      To: #{to}
      Subject: #{encode_header(subject)}
      MIME-Version: 1.0
      Content-Type: multipart/related; boundary="#{boundary}"

      #{parts}
    MSG

    smtp = Net::SMTP.new(creds[:server], creds[:port].to_i)
    smtp.enable_starttls_auto
    smtp.start(creds[:domain], creds[:user_name], creds[:password], :plain) { |s| s.send_message(message, from, to) }
  end

  def self.encode_header(text)
    "=?UTF-8?B?#{[text].pack("m0")}?="
  end
end
