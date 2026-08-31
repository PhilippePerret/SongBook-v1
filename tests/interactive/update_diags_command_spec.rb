# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"

# `update diags` : régénère les diagrammes SVG manquants de l'application ET la page
# HTML qui les liste toutes  — remplace l'alias `build-diags`).
RSpec.describe "commande update diags" do
  it "produit les diagrammes manquants ET régénère la page HTML" do
    expect(GenerateChordDiagrams).to receive(:run).and_return([[], []])
    expect(DiagsPage).to receive(:build!)

    CLI.run(%w[update diags], interactive: true)
  end

  it "refuse une sous-commande inconnue" do
    expect { CLI.run(%w[update bidule], interactive: true) }.to raise_error(SystemExit)
  end
end

# `diags` : jamais de chemin affiché (règle du projet, aucun path en sortie).
RSpec.describe "commande diags" do
  it "n'affiche aucun chemin" do
    chemin = File.join(Dir.home, "Documents", "all-diags.html")
    allow(DiagsPage).to receive(:build_and_open!).and_return(chemin)

    expect { CLI.run(%w[diags], interactive: true) }.not_to output(/#{Regexp.escape(chemin)}|~\//).to_stdout
  end
end
