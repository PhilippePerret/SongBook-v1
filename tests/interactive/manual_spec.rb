# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"

# Tests du mode interactif
RSpec.describe "commande manual/manuel" do
  before do
    allow(CLI).to receive(:system).and_return(true)
  end

  it "Ouvrir le manuel" do
    expect(CLI).to receive(:system).with("open", end_with("Manuel.html"))
    CLI.run(%w[manual], interactive: true)
  end

  it "Chercher un mot dans tout le manuel" do
    expect { CLI.run(%w[manuel riff], interactive: true) }.to output(/riff/).to_stdout
  end

  it "Dire qu'on n'a rien trouvé plutôt que de rien afficher" do
    expect { CLI.run(["manuel", "zzzzzxxxxxqqqqq"], interactive: true) }.to output(/rien trouvé/).to_stdout
  end
end
