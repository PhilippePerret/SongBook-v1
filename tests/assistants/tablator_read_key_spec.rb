# frozen_string_literal: true

require_relative "../spec_helper"
require "tablator_assistant"

# `TablatorAssistant.read_key` : une séquence ESC qui n'est PAS une CSI ("\e[...") ne
# doit JAMAIS attendre un octet de plus après les 2 premiers (Phil, 2026-08-27 — bug
# constaté : Option/Alt+lettre envoyé en "Meta" par le terminal, ex. "\e" + "L", faisait
# bloquer la lecture jusqu'à la frappe SUIVANTE, avalée à tort comme si elle appartenait
# à cette séquence).
RSpec.describe "TablatorAssistant.read_key" do
  def stub_getc(*chars)
    i = -1
    allow($stdin).to receive(:getc) do
      i += 1
      chars[i]
    end
  end

  it "touche simple : renvoyée telle quelle, un seul octet lu" do
    stub_getc("a")
    expect(TablatorAssistant.read_key).to eq("a")
    expect($stdin).to have_received(:getc).once
  end

  it "flèche (CSI courte, \"\\e[A\") : reconnue, 3 octets lus" do
    stub_getc("\e", "[", "A")
    expect(TablatorAssistant.read_key).to eq(:up)
    expect($stdin).to have_received(:getc).exactly(3).times
  end

  it "Maj+flèche (CSI longue, \"\\e[1;2C\") : reconnue, 6 octets lus" do
    stub_getc("\e", "[", "1", ";", "2", "C")
    expect(TablatorAssistant.read_key).to eq(:shift_right)
    expect($stdin).to have_received(:getc).exactly(6).times
  end

  it "ESC + lettre SANS \"[\" (Option/Alt en Meta, ex. \"\\eL\") : renvoyée après 2 octets SEULEMENT, n'attend pas un 3e" do
    stub_getc("\e", "L", "z") # "z" ne doit JAMAIS être consommé par cette lecture
    expect(TablatorAssistant.read_key).to eq("\eL")
    expect($stdin).to have_received(:getc).exactly(2).times
  end
end
