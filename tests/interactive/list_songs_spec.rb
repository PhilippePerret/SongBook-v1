# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"

# Tests du mode interactif
RSpec.describe "commande list songs" do
  before { CLI.run(["use", "songbook", "Carnet-Test"], interactive: true) }

  it "Donner juste les titres par défaut, un par ligne" do
    expect { CLI.run(%w[list songs], interactive: true) }.to output(/Angie\nAngie\n/).to_stdout
  end

  it "Utiliser le gabarit et le séparateur donnés" do
    expect { CLI.run(["list", "songs", "{title} ({performer})", ", "], interactive: true) }
      .to output(/Angie \(Rolling Stones\), Angie \(Rolling Stones\)/).to_stdout
  end

  it "Refuser de lister sans contexte de carnet" do
    Session.carnet = nil
    Dir.chdir(FIXTURE_SONGS_DIR) do
      expect { CLI.run(%w[list songs], interactive: true) }.to raise_error(SystemExit)
    end
  end
end
