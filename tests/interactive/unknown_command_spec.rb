# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"

# Tests du mode interactif
RSpec.describe "commande inconnue ou incomplète" do
  it "Dire juste commande inconnue sans tout expliquer" do
    message = begin
      CLI.run(%w[bidule], interactive: true)
    rescue SystemExit => e
      e.message
    end
    expect(message).to include("bidule")
    expect(message.length).to be < 100
  end
end
