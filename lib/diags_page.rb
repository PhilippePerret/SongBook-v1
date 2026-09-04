# frozen_string_literal: true

require_relative "chord_diagrams"
require_relative "dsl_parser"

# Page HTML unique regroupant tous les diagrammes d'accords disponibles
# (assets/chords_diags), en deux groupes distincts (majeurs puis mineurs),
# chaque groupe classé par note chromatique (dièse ET bémol séparés quand
# les deux orthographes existent). Diagrammes pris tels quels (le nom de
# l'accord est déjà dessiné dans le SVG, aucune légende ajoutée ici).
module DiagsPage
  OUT_PATH = File.expand_path("../assets/all-diags.html", __dir__)

  # [lettre, accidentale ("b"/"d"/nil), nom affiché (anglais, vrais ♯/♭)]
  # — ordre chromatique, dièse puis bémol quand les deux orthographes
  # existent (ex. C♯, D♭).
  CHROMATIC = [
    ["C", nil, "C"],
    ["C", "d", "C♯"],
    ["D", "b", "D♭"],
    ["D", nil, "D"],
    ["D", "d", "D♯"],
    ["E", "b", "E♭"],
    ["E", nil, "E"],
    ["F", nil, "F"],
    ["F", "d", "F♯"],
    ["G", nil, "G"],
    ["G", "d", "G♯"],
    ["A", nil, "A"],
    ["A", "b", "A♭"],
    ["A", "d", "A♯"],
    ["B", "b", "B♭"],
    ["B", nil, "B"],
  ].freeze

  # Lettre en tête acceptée en minuscule aussi (bug constaté : "c[e]-0B.svg" jamais
  # reconnu, invisible de cette page, alors que le nom est valide — même règle partout
  # ailleurs, un nom d'accord s'écrit comme l'user veut).
  FILENAME_RE = /\A([A-Ga-g])(b|d)?(.*)-(\d+)([A-Za-z]*)\z/.freeze

  def self.build_and_open!
    build! if stale?
    system("open", OUT_PATH)
    OUT_PATH
  end

  def self.stale?
    return true unless File.exist?(OUT_PATH)

    out_mtime = File.mtime(OUT_PATH)
    svg_files.any? { |f| File.mtime(f) > out_mtime }
  end

  def self.svg_files
    Dir.glob(File.join(ChordDiagrams::ASSETS, "*", "*.svg")).reject { |f| f =~ /-old\.svg\z/i }
  end

  def self.minor?(quality)
    quality.start_with?("m") && !quality.start_with?("maj")
  end

  def self.build!
    buckets = Hash.new { |h, k| h[k] = [] }
    svg_files.each do |f|
      base = File.basename(f, ".svg")
      m = FILENAME_RE.match(base)
      next unless m

      letter, accidental, quality, kase = m[1].upcase, m[2], m[3], m[4].to_i
      buckets[[letter, accidental]] << { file: f, quality: quality, case: kase }
    end
    buckets.each_value { |entries| entries.sort_by! { |e| [e[:quality], e[:case]] } }

    sections = CHROMATIC.flat_map do |letter, accidental, name|
      all = buckets[[letter, accidental]]
      majors = all.select { |e| !minor?(e[:quality]) }
      minors = all.select { |e| minor?(e[:quality]) }

      out = []
      out << [slug(letter, accidental), name, majors] if majors.any?
      out << ["#{slug(letter, accidental)}m", "#{name}m", minors] if minors.any?
      out
    end

    File.write(OUT_PATH, render(sections))
    OUT_PATH
  end

  def self.slug(letter, accidental)
    "#{letter.downcase}#{accidental == "d" ? "-diese" : accidental == "b" ? "-bemol" : ""}"
  end

  def self.render(sections)
    <<~HTML
      <!DOCTYPE html>
      <html lang="fr">
      <head>
      <meta charset="utf-8">
      <title>Tous les diagrammes d'accords</title>
      <style>
        body { font-family: sans-serif; margin: 2em; }
        header.page-title { text-align: right; color: #888; font-size: 1.55em; margin-bottom: 1.5em; }
        nav { display: flex; flex-wrap: wrap; gap: 0.6em; margin: 1em 0 2.5em; font-size: 1.1em; }
        nav a { text-decoration: none; padding: 0.2em 0.6em; border: 1px solid #999; border-radius: 4px; }
        .nav-hint { margin: 0 0 0.3em; font-style: italic; color: #888; text-align: center; }
        section { margin-bottom: 2.5em; }
        h2 { display: flex; justify-content: space-between; align-items: center; background: #222; color: #fff; padding: 0.4em 0.8em; border-radius: 4px; }
        h2 a.top-link { color: #ccc; text-decoration: none; font-size: 0.55em; font-weight: normal; }
        .grid { display: flex; flex-wrap: wrap; gap: 1em; }
        .grid figure { position: relative; margin: 0; text-align: center; }
        .grid img { height: 160px; display: block; cursor: pointer; }
        .grid figcaption { color: #444; font-weight: 600; font-size: 0.95em; line-height: 1; margin: 2px 0 0; }
        .copy-toast {
          position: fixed;
          transform: translate(-50%, -100%);
          background: #a8e6b8; color: #000000;
          padding: 0.5em 1em; border-radius: 6px;
          font-size: 0.95em; font-weight: normal; white-space: nowrap;
          text-align: center;
          box-shadow: 0 2px 8px rgba(0,0,0,0.35);
          pointer-events: none;
          z-index: 1000;
          animation: copy-toast-fade 4s ease forwards;
        }
        @keyframes copy-toast-fade {
          0%   { opacity: 0; }
          10%  { opacity: 1; }
          80%  { opacity: 1; }
          100% { opacity: 0; }
        }
        .footer-note { margin-top: 2em; font-style: italic; }
        .footer-note code { background: #222; color: #fff; padding: 0.2em 0.5em; border-radius: 3px; font-style: normal; }
      </style>
      </head>
      <body id="top">
      <header class="page-title">Diagrammes de l'application <strong>SongBook</strong></header>
      <nav>
      #{sections.map { |slug, name, _| %(<a href="##{slug}">#{name}</a>) }.join("\n")}
      </nav>
      <p class="nav-hint">(Utiliser le nom présenté sous le diagramme dans vos chansons — cliquer sur le diagramme pour mettre son nom dans le presse-papier)</p>
      #{sections.map { |slug, name, entries| render_section(slug, name, entries) }.join("\n")}
      <hr>
      <p class="footer-note">Pour produire votre propre diagramme, utilisez la commande <code>diag -o</code> ou <code>console build diag "&lt;schéma&gt;"</code>.</p>
      <script>
      function showCopyToast(event, text) {
        var toast = document.createElement('span');
        toast.className = 'copy-toast';
        toast.textContent = text + ' dans le presse-papier';
        toast.style.left = event.clientX + 'px';
        toast.style.top = (event.clientY - 20) + 'px';
        document.body.appendChild(toast);
        toast.addEventListener('animationend', function () { toast.remove(); });
      }

      document.querySelectorAll('img[data-copy]').forEach(function (img) {
        img.addEventListener('click', function (event) {
          var text = img.getAttribute('data-copy');
          if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text);
          } else {
            var ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            document.execCommand('copy');
            document.body.removeChild(ta);
          }
          showCopyToast(event, text);
        });
      });
      </script>
      </body>
      </html>
    HTML
  end

  def self.grid(entries)
    imgs = entries.map do |e|
      rel = File.join(File.basename(File.dirname(e[:file])), File.basename(e[:file]))
      # Presse-papier = syntaxe TAPÉE dans un `.lyr` (crochets, canonique, jamais
      # renommée sur le disque) ; légende = la même chose AFFICHÉE (`Layout.display_chord`
      # — basse en solfège italien, notation slash, jamais les crochets : "C/mi", jamais
      # "C[E]", même règle que PARTOUT ailleurs dans l'app).
      fname = File.basename(e[:file], ".svg")
      m = fname.match(/\A([^-]+)-(.+)\z/)
      nom = m ? DSLParser.normalize_chord(m[1]) : fname
      case_ref = m && m[2]
      to_copy = case_ref ? "#{nom}-#{case_ref}" : nom
      shown = case_ref ? "#{Layout.display_chord(nom)}-#{case_ref}" : Layout.display_chord(nom)
      %(<figure><img src="chords_diags/#{rel}" alt="" data-copy="/#{to_copy}:"><figcaption>/#{shown}:</figcaption></figure>)
    end.join("\n")

    %(<div class="grid">\n#{imgs}\n</div>)
  end

  def self.render_section(id, name, entries)
    <<~HTML
      <section id="#{id}">
      <h2><span>#{name}</span><a class="top-link" href="#top">haut de page</a></h2>
      #{grid(entries)}
      </section>
    HTML
  end
end
