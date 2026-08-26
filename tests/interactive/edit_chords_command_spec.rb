# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "session"
require "file_finder"

# Tests du mode interactif — commande `edit chords` (remplace l'ancienne `add chords`)
RSpec.describe "commande edit chords" do
  it "'edit chords' route vers ChordPlacer.run sur le .lyr de la chanson en contexte" do
    CLI.run(%w[use song Angie], interactive: true)
    lyr_path = FileFinder.find(Session.song, :lyr)

    expect(ChordPlacer).to receive(:run).with(lyr_path)
    CLI.run(%w[edit chords], interactive: true)
  end

  it "'add chords' (ancienne commande) n'existe plus" do
    expect { CLI.run(%w[add chords], interactive: true) }.to raise_error(SystemExit)
  end

  it "'edit bidule' (sous-commande inconnue) reste une commande inconnue" do
    expect { CLI.run(%w[edit bidule], interactive: true) }.to raise_error(SystemExit)
  end
end
