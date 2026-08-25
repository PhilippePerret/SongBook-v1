# frozen_string_literal: true

require_relative "../spec_helper"
require "shellwords"

# Tests du mode interactif
#
# Test resserré sur le déclencheur exact du bug (guillemet non fermé -> exception
# `Shellwords.split`) : le mode interactif lui-même (`CLI.run_interactive`) lit un
# vrai terminal et n'est pas testable ici — la boucle REPL attrape cette exception
# précise (voir `lib/cli.rb`, `rescue ArgumentError` autour de `Shellwords.split`).
RSpec.describe "ligne tapée dans le mode interactif" do
  it "Ne pas planter si on oublie de fermer un guillemet" do
    expect { Shellwords.split('tdm "titre oublié') }.to raise_error(ArgumentError)
  end

  it "une ligne normale ne pose aucun problème" do
    expect(Shellwords.split('tdm "Carnet-Test"')).to eq(%w[tdm Carnet-Test])
  end
end
