# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"

# Tests du mode interactif
RSpec.describe "commande tdm" do
  it "Ouvrir la table des matières d'un carnet par son titre" do
    expect(CLI).to receive(:system).with("open", "-a", "TextEdit", end_with(".tdm"))
    CLI.run(%w[tdm Carnet-Test], interactive: true)
  end

  it "Refuser un carnet introuvable pour la table des matières" do
    expect { CLI.run(%w[tdm zzzzzxxxxxqqqqq], interactive: true) }.to raise_error(SystemExit)
  end
end
