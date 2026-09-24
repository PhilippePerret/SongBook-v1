# frozen_string_literal: true

require "cgi"
require_relative "rights_manager"
require_relative "rights_expiry"
require_relative "carnet_builder"
require_relative "file_finder"
require_relative "app_config"
require_relative "songs_list"
require_relative "song_resolver"

# Rapport HTML de l'état des demandes de droits pour un carnet (Phil, 2026-09-22,
# "Afficher un rapport [HTML] de l'état des demandes"). Table triable en cliquant les
# en-têtes (chanson/éditeur/statut/dernière action) — plutôt qu'un tri fixé côté Ruby,
# vu la demande explicite de "plusieurs classements possibles".
module RightsReport
  STATUS_LABELS = {
    "none" => "—",
    "sent" => "Demande envoyée",
    "negotiating" => "En négociation",
    "authorized" => "Autorisé",
    "contract_signed" => "Autorisation accordée",
    "refused" => "Refusé",
  }.freeze

  # Autorisation obtenue -> vert ; en cours (au moins le premier contact envoyé) ->
  # orange ; rien fait ou refusé -> rouge (Phil, 2026-09-22, "en train d'être traitée,
  # c'est-à-dire que, au moins, le premier contact a été envoyé").
  AUTHORIZED_STATUSES = %w[authorized contract_signed].freeze
  IN_PROGRESS_STATUSES = %w[sent negotiating].freeze

  def self.progress_color(status)
    return "green" if AUTHORIZED_STATUSES.include?(status)
    return "orange" if IN_PROGRESS_STATUSES.include?(status)

    "red"
  end

  # `carnet_folder` -> chemin du fichier HTML généré (dans le dossier du carnet,
  # écrasé à chaque génération — c'est un rapport, pas un historique de rapports).
  def self.generate(carnet_folder)
    rows = SongsList.entries(carnet_folder: carnet_folder).map { |e| row_for(e) }
    html = render(carnet_title: SongResolver.display_name(carnet_folder), rows: rows)
    path = File.join(carnet_folder, "rapport-droits.html")
    File.write(path, html)
    path
  end

  # NB : `entry[:infos]` (fourni par `SongsList`) vient de `PageBuilder.parse_infos`, un
  # parseur PLAT qui ignore l'indentation (distinct de `CarnetBuilder.parse_nested_infos`
  # — écart pré-existant dans le projet, pas introduit ici) : un bloc imbriqué comme
  # `music_publisher:` y remonte éclaté à la racine, donc on relit le `.infos` via le
  # parseur imbriqué plutôt que de faire confiance à `entry[:infos]` pour ces clés-là.
  def self.row_for(entry)
    folder = File.join(AppConfig.songs_dir, entry[:folder])
    infos_path = FileFinder.find(folder, :inf)
    infos = infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : entry[:infos]
    publishers = RightsManager.publisher_list(infos)
    rights = infos["reproduction_rights"]
    history = RightsManager.rights_history(infos)
    status = RightsManager.rights_status(infos)
    expiry = rights.is_a?(Hash) ? RightsExpiry.expiry_date(rights) : nil
    {
      title: infos["title"].to_s,
      folder: folder,
      publishers: publishers,
      status: status,
      progress_color: progress_color(status),
      last_action: history.last.to_s,
      expiry: expiry,
    }
  end

  def self.render(carnet_title:, rows:)
    body_rows = rows.map do |r|
      names = r[:publishers].map { |p| p["name"] }.reject { |n| n.to_s.empty? }.join(", ")
      emails = r[:publishers].filter_map { |p| p["email"] unless p["email"].to_s.empty? }
      contacts = if emails.any?
                   emails.map { |e| "<a href=\"mailto:#{h(e)}\">#{h(e)}</a>" }.join(", ")
                 else
                   r[:publishers].filter_map { |p| address_line(p) unless p["address"].to_s.empty? }.join("<br>")
                 end
      <<~ROW
        <tr data-progress="#{r[:progress_color]}">
          <td>#{h(r[:title])}</td>
          <td title="#{h(names)}">#{h(names)}</td>
          <td>#{contacts}</td>
          <td data-status="#{h(r[:status])}">#{h(STATUS_LABELS.fetch(r[:status], r[:status]))}</td>
          <td>#{h(r[:last_action])}</td>
          <td>#{r[:expiry] ? h(r[:expiry].iso8601) : ""}</td>
        </tr>
      ROW
    end.join

    <<~HTML
      <!doctype html>
      <html lang="fr">
      <head>
      <meta charset="utf-8">
      <title>État des droits — #{h(carnet_title)}</title>
      <style>
        body { font-family: -apple-system, sans-serif; margin: 2rem; color: #222; }
        h1 { font-size: 1.3rem; }
        table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
        th, td { border: 1px solid #ccc; padding: 0.4rem 0.6rem; text-align: left; font-size: 0.9rem; }
        th { background: #f0f0f0; cursor: pointer; user-select: none; white-space: nowrap; }
        th:hover { background: #e0e0e0; }
        th::after { content: " ⇅"; color: #999; font-size: 0.75em; }
        th:nth-child(2), td:nth-child(2) { max-width: 12rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        th:nth-child(4), td:nth-child(4) { min-width: 12rem; }
        th:nth-child(6), td:nth-child(6) { min-width: 6.5rem; }
        tr:nth-child(even) { background: #fafafa; }
        /* Autorisation obtenue -> vert ; en cours (au moins premier contact envoyé) ->
           orange ; rien fait/refusé -> rouge — "la chanson" (1re colonne) porte la
           couleur, pas toute la ligne (Phil, 2026-09-22). */
        tr[data-progress="red"] td:first-child { border-left: 4px solid #e74c3c; color: #c0392b; font-weight: 600; }
        tr[data-progress="orange"] td:first-child { border-left: 4px solid #f39c12; color: #d68910; font-weight: 600; }
        tr[data-progress="green"] td:first-child { border-left: 4px solid #27ae60; color: #1e8449; font-weight: 600; }
        td[data-status="none"] { color: #999; }
        td[data-status="refused"] { color: #c0392b; }
        td[data-status="sent"], td[data-status="negotiating"] { color: #d68910; }
        td[data-status="authorized"], td[data-status="contract_signed"] { color: #1e8449; font-weight: 600; }
        .copy-addr { border: none; background: none; cursor: pointer; font-size: 0.9em; padding: 0 0.2em; vertical-align: middle; }
      </style>
      </head>
      <body>
      <h1>État des droits — #{h(carnet_title)}</h1>
      <p>#{rows.size} chanson(s). Cliquer un en-tête de colonne pour trier.</p>
      <table id="rights-table">
        <thead>
          <tr>
            <th>Chanson</th>
            <th>Éditeur</th>
            <th>Contact</th>
            <th>Statut</th>
            <th>Dernière action</th>
            <th>Expiration</th>
          </tr>
        </thead>
        <tbody>
          #{body_rows}
        </tbody>
      </table>
      <script>
        document.querySelectorAll("#rights-table th").forEach(function(th, i) {
          var asc = true;
          th.addEventListener("click", function() {
            var tbody = document.querySelector("#rights-table tbody");
            var rows = Array.from(tbody.querySelectorAll("tr"));
            rows.sort(function(a, b) {
              var av = a.children[i].textContent.trim().toLowerCase();
              var bv = b.children[i].textContent.trim().toLowerCase();
              // Cellules vides toujours en dernier, quel que soit le sens du tri.
              if (av === "" && bv === "") return 0;
              if (av === "") return 1;
              if (bv === "") return -1;
              return asc ? av.localeCompare(bv) : bv.localeCompare(av);
            });
            rows.forEach(function(r) { tbody.appendChild(r); });
            asc = !asc;
          });
        });
        document.querySelectorAll(".copy-addr").forEach(function(btn) {
          btn.addEventListener("click", function() {
            navigator.clipboard.writeText(btn.dataset.copy).then(function() {
              var original = btn.textContent;
              btn.textContent = "✅";
              setTimeout(function() { btn.textContent = original; }, 1200);
            });
          });
        });
      </script>
      </body>
      </html>
    HTML
  end

  # Adresse physique + picto de copie (nom + adresse ensemble dans le presse-papier, via
  # `data-copy`, lu par le script en pied de page — voir `render`).
  def self.address_line(p)
    copy_text = [p["name"], p["address"]].map(&:to_s).reject(&:empty?).join(", ")
    "#{h(p["address"])} <button class=\"copy-addr\" data-copy=\"#{h(copy_text)}\" title=\"Adresse dans le presse-papier\">📋</button>"
  end

  def self.h(text)
    CGI.escapeHTML(text.to_s)
  end
end
