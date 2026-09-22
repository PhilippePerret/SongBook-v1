# frozen_string_literal: true

require "ferrum"

# Client du répertoire PUBLIC de la Sacem (repertoire.sacem.fr) — SEULE source utilisée
# pour `music_publisher` (RightsManager), y compris pour les œuvres étrangères : une
# œuvre anglophone y apparaît avec un "Sous Éditeur" (le sous-éditeur français, donc
# l'interlocuteur réel pour négocier des droits en France — vérifié sur "Blowin' in the
# Wind"/Dylan -> UNIVERSAL MUSIC PUBLISHING). Un vrai Chrome (pas Net::HTTP/curl) est
# nécessaire : le site est derrière un WAF CloudFront qui bloque tout client sans moteur
# JS — et bloque même Chrome headless SANS user-agent desktop (le token
# "HeadlessChrome" par défaut suffit à le faire bloquer, vérifié).
class SacemClient
  BASE_URL = "https://www.repertoire.sacem.fr"
  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
               "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

  def initialize
    @browser = Ferrum::Browser.new(
      headless: true,
      timeout: 30,
      browser_options: { "no-sandbox" => nil, "user-agent" => USER_AGENT, "lang" => "fr-FR" }
    )
    @page = @browser.create_page
  end

  def close
    @browser.quit
  rescue StandardError
    nil
  end

  # `title`/`creator` -> liste d'items `{ "title" =>, "fields" => {"Editeur"|"Sous
  # Editeur"|"Compositeur"|... =>}, "href" => }`, [] si aucun résultat. Le moteur de
  # recherche Sacem ne matche pas bien "Prénom NOM complet" (vérifié : "Maxime Le
  # Forestier" -> 0 résultat, "Le Forestier" -> 2 ; "Bob Dylan" -> 0, "Dylan" -> 3) —
  # on retente donc avec le dernier puis le premier mot de `creator` avant d'abandonner.
  def search(title, creator)
    queries = [creator, last_word(creator), first_word(creator), ""].map(&:to_s).map(&:strip).uniq
    queries.each do |q|
      results = run_search(title, q)
      return results unless results.empty?
    end
    []
  end

  # Fiche détail d'une œuvre (`href` du résultat de recherche) -> `{ "iswc" =>,
  # "publisher" => { "label" => "Éditeur"|"Sous Éditeur", "name" =>, "ipi" =>,
  # "address" =>, "email" => } }` (`"publisher" => nil` si la page n'a pas de section
  # éditeur exploitable).
  def fetch_detail(href)
    url = href.to_s.start_with?("http") ? href : "#{BASE_URL}#{href}"
    @page.go_to(url)
    wait_until(timeout: 12) { @page.evaluate("!!document.querySelector('.bgdUniv h2')") }
    @page.evaluate(DETAIL_JS)
  end

  private

  def last_word(str) = str.to_s.strip.split(/\s+/).last
  def first_word(str) = str.to_s.strip.split(/\s+/).first

  # Ferrum lève une `ArgumentError` sur `.type("")` (`Ferrum::Keyboard#normalize_keys`,
  # "empty keys passed") — un champ vide se laisse simplement vide, jamais tapé (le
  # champ créateur PEUT être vide, voir le fallback `""` de `search`).
  def type_into(selector, text)
    return if text.to_s.strip.empty?

    @page.at_css(selector)&.focus&.type(text.to_s)
  end

  def run_search(title, creator)
    @page.go_to("#{BASE_URL}/")
    wait_until(timeout: 12) { @page.evaluate("!!document.getElementById('idFullSearch')") }
    type_into("#idFullSearch", title)
    type_into("#idCreatorSearch", creator)
    @page.at_css("#searchBtn")&.click
    wait_until(timeout: 12) do
      @page.evaluate("(function(){var c=document.getElementById('resultatRecherche');return !!c && c.textContent.trim().length>0;})()")
    end
    @page.evaluate(RESULTS_JS)
  end

  def wait_until(timeout:)
    deadline = Time.now + timeout
    sleep 0.25 until yield || Time.now > deadline
  end

  RESULTS_JS = <<~JS.freeze
    (function() {
      var container = document.getElementById('resultatRecherche');
      if (!container) return [];
      if (container.textContent.indexOf('Aucun résultat') !== -1) return [];
      return Array.from(container.querySelectorAll('.whiteBlc.mod')).map(function(div) {
        var h2 = div.querySelector('h2');
        var title = h2 ? h2.textContent.trim() : null;
        var fields = {};
        div.querySelectorAll('p.mb1').forEach(function(p) {
          var labelSpan = p.querySelector('span.txtB');
          if (!labelSpan) return;
          var label = labelSpan.textContent.replace(':', '').trim();
          var spans = Array.from(p.querySelectorAll('span'));
          fields[label] = spans.slice(1).map(function(s){ return s.textContent.trim(); }).join(' / ');
        });
        var a = div.querySelector('a[href*="detail-oeuvre"]');
        return { title: title, fields: fields, href: a ? a.getAttribute('href') : null };
      });
    })()
  JS

  # Le bloc "Ayants droit" donne le VRAI rôle (Editeur / Sous Editeur) ; le `h3` du
  # bloc contact en bas de page est TOUJOURS littéralement "Éditeur", même pour un
  # sous-éditeur étranger (vérifié sur "Ecoute dans le vent"/Dylan -> Sous Éditeur
  # Universal, mais `h3` = "Éditeur" quand même) — le rôle est donc lu là-bas, pas
  # dans ce `h3`. Le conteneur direct du bloc contact (`.grid2.borderBoxMod.mod.mb1`,
  # seule classe combinée qui identifie ce bloc PARMI les autres `.grid2` de la page —
  # ex. celui d'"Interprète", répété par interprète, n'a jamais `.mb1`) est parfois le
  # frère direct du `h3`, parfois enveloppé dans un `<div>` intermédiaire
  # supplémentaire selon les œuvres (constaté, pas documenté par la Sacem) — cherché
  # par classe dans TOUT le parent du `h3` plutôt que par position fixe.
  DETAIL_JS = <<~JS.freeze
    (function() {
      function txt(el) { return el ? el.textContent.trim() : null; }
      var headings = function(label) {
        return Array.from(document.querySelectorAll('h3.cUniv.txtUpp')).find(function(h) {
          return h.textContent.trim().toLowerCase() === label;
        });
      };

      var iswc = null;
      document.querySelectorAll('.bgdUniv p.mt1').forEach(function(p) {
        if (p.textContent.indexOf('ISWC') !== -1) iswc = p.textContent.replace(/.*ISWC\\s*:\\s*/, '').trim();
      });

      var role = null;
      var ayantsH3 = headings('ayants droit');
      if (ayantsH3 && ayantsH3.nextElementSibling) {
        var roleP = Array.from(ayantsH3.nextElementSibling.querySelectorAll('p')).find(function(p) {
          return /,\\s*(sous\\s+)?[ée]diteur/i.test(p.textContent);
        });
        if (roleP) role = roleP.textContent.replace(/^.*,\\s*/, '').trim();
      }

      var pubHeading = headings('éditeur');
      if (!pubHeading) return { iswc: iswc, publisher: null };

      var block = pubHeading.parentElement
        ? pubHeading.parentElement.querySelector('.grid2.borderBoxMod.mod.mb1')
        : null;
      if (!block) return { iswc: iswc, publisher: { label: role, name: null, ipi: null, address: null, email: null } };

      var ps = Array.from(block.children).filter(function(c) { return c.tagName === 'P'; });
      var name = ps[0] ? txt(ps[0]) : null;
      var ipiP = ps.find(function(p) { return p.textContent.indexOf('Code IPI') !== -1; });
      var ipi = ipiP ? ipiP.textContent.replace('Code IPI', '').replace(':', '').trim() : null;

      var addrDiv = block.querySelector('div.grid2.borderBoxMod.mod');
      var address = null;
      if (addrDiv) {
        var addrP = addrDiv.querySelector('p');
        address = addrP ? addrP.innerText.trim().replace(/\\n+/g, ', ') : null;
      }

      var emailP = Array.from(block.children).find(function(c) {
        return c.tagName === 'P' && !c.className && c.textContent.indexOf('@') !== -1;
      });
      var email = emailP ? txt(emailP) : null;

      return { iswc: iswc, publisher: { label: role, name: name, ipi: ipi, address: address, email: email } };
    })()
  JS
end
