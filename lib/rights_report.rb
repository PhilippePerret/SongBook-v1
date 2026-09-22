# frozen_string_literal: true

require "cgi"
require_relative "rights_manager"
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
    "contract_signed" => "Contrat signé",
    "refused" => "Refusé",
  }.freeze

  # Autorisation obtenue -> vert ; tout le reste (y compris refusé) -> rouge, tant que
  # les paroles ne sont pas couvertes par un droit accordé (Phil, 2026-09-22).
  AUTHORIZED_STATUSES = %w[authorized contract_signed].freeze

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
    publisher = infos["music_publisher"].is_a?(Hash) ? infos["music_publisher"] : {}
    history = RightsManager.rights_history(infos)
    status = RightsManager.rights_status(infos)
    {
      title: infos["title"].to_s,
      folder: folder,
      publisher_name: publisher["name"].to_s,
      publisher_email: publisher["email"].to_s,
      status: status,
      authorized: AUTHORIZED_STATUSES.include?(status),
      last_action: history.last.to_s,
    }
  end

  def self.render(carnet_title:, rows:)
    body_rows = rows.map do |r|
      <<~ROW
        <tr data-authorized="#{r[:authorized] ? "yes" : "no"}">
          <td>#{h(r[:title])}</td>
          <td>#{h(r[:publisher_name])}</td>
          <td>#{r[:publisher_email].to_s.empty? ? "" : "<a href=\"mailto:#{h(r[:publisher_email])}\">#{h(r[:publisher_email])}</a>"}</td>
          <td data-status="#{h(r[:status])}">#{h(STATUS_LABELS.fetch(r[:status], r[:status]))}</td>
          <td>#{h(r[:last_action])}</td>
        </tr>
      ROW
    end.join

    <<~HTML
      <!doctype html>
      <html lang="fr">
      <head>
      <meta charset="utf-8">
      <title>Droits — #{h(carnet_title)}</title>
      <style>
        body { font-family: -apple-system, sans-serif; margin: 2rem; color: #222; }
        h1 { font-size: 1.3rem; }
        table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
        th, td { border: 1px solid #ccc; padding: 0.4rem 0.6rem; text-align: left; font-size: 0.9rem; }
        th { background: #f0f0f0; cursor: pointer; user-select: none; }
        th:hover { background: #e0e0e0; }
        th::after { content: " ⇅"; color: #999; font-size: 0.75em; }
        tr:nth-child(even) { background: #fafafa; }
        /* Autorisation obtenue -> vert ; sinon (y compris refusé) -> rouge — "la chanson"
           (1re colonne) porte la couleur, pas toute la ligne (Phil, 2026-09-22). */
        tr[data-authorized="no"] td:first-child { border-left: 4px solid #e74c3c; color: #c0392b; font-weight: 600; }
        tr[data-authorized="yes"] td:first-child { border-left: 4px solid #27ae60; color: #1e8449; font-weight: 600; }
        td[data-status="none"] { color: #999; }
        td[data-status="refused"] { color: #c0392b; }
        td[data-status="authorized"], td[data-status="contract_signed"] { color: #1e8449; font-weight: 600; }
      </style>
      </head>
      <body>
      <h1>État des demandes de droits — #{h(carnet_title)}</h1>
      <p>#{rows.size} chanson(s). Cliquer un en-tête de colonne pour trier.</p>
      <table id="rights-table">
        <thead>
          <tr>
            <th>Chanson</th>
            <th>Éditeur</th>
            <th>Email</th>
            <th>Statut</th>
            <th>Dernière action</th>
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
              return asc ? av.localeCompare(bv) : bv.localeCompare(av);
            });
            rows.forEach(function(r) { tbody.appendChild(r); });
            asc = !asc;
          });
        });
      </script>
      </body>
      </html>
    HTML
  end

  def self.h(text)
    CGI.escapeHTML(text.to_s)
  end
end
