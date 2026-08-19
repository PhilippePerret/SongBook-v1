# version 2.1
require 'asciidoctor'
require 'asciidoctor/extensions'

class Combo < Asciidoctor::Extensions::InlineMacroProcessor
  use_dsl

  named :combo

  STRKEYS_TO_KEY = {
    'alt'   => '⌥',
    'cmd'   => '⌘',
    'ctrl'  => '⌃', 
    'maj'   => '⇧',
    'enter' => '↩︎',
    'fb'    => '↓',
    'fg'    => '←',
    'fh'    => '↑',
    'fd'    => '→',
  }

  def process(parent, target, attrs)
    html = target.split('+').map {|k| %(<kbd style="font-size:1.25em;">#{STRKEYS_TO_KEY[k.downcase] || k}</kbd>) }.join('+')
    create_anchor(parent, html, type: :link)
  end
end

Asciidoctor::Extensions.register do
  inline_macro Combo
end