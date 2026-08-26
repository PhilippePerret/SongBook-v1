# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "session"
require "tablator_assistant"

# Tests du mode interactif — commande `create tab` (nouvelle tablature dans la
# chanson en contexte, jamais dans un carnet seul).
RSpec.describe "commande create tab" do
  it "refuse sans aucun contexte" do
    expect { CLI.run(%w[create tab], interactive: true) }.to raise_error(SystemExit)
  end

  it "refuse avec seulement un carnet en contexte (jamais dans un carnet)" do
    CLI.run(%w[use songbook Carnet-Test], interactive: true)
    expect { CLI.run(%w[create tab], interactive: true) }.to raise_error(SystemExit)
  end

  it "avec un nom : passe ce nom en 'title', sans le redemander (.tab absent)" do
    CLI.run(%w[use song Angie], interactive: true)

    expect(TablatorAssistant).to receive(:write_tablature).with(title: "Intro Solo")
    CLI.run(["create", "tab", "Intro Solo"], interactive: true)
  end

  it "avec un nom se terminant par .tab : le suffixe est retiré avant de passer 'title'" do
    CLI.run(%w[use song Angie], interactive: true)

    expect(TablatorAssistant).to receive(:write_tablature).with(title: "Intro Solo")
    CLI.run(["create", "tab", "Intro Solo.tab"], interactive: true)
  end

  it "sans nom : title nil, redemandé interactivement (Titre :) plus tard" do
    CLI.run(%w[use song Angie], interactive: true)

    expect(TablatorAssistant).to receive(:write_tablature).with(title: nil)
    CLI.run(%w[create tab], interactive: true)
  end

  it "--song fixe aussi le contexte pour create tab (Session.with_song)" do
    expect(TablatorAssistant).to receive(:write_tablature).with(title: "Riff")
    CLI.run(["create", "tab", "Riff", "--song", "Angie"], interactive: true)
  end
end
