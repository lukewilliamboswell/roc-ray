# frozen_string_literal: true

require "asciidoctor"
require "asciidoctor/extensions"

# Asciidoctor extensions for the RocRay manual, loaded with `-r` by
# scripts/build_manual.py for both the HTML and the PDF build.

# ---------------------------------------------------------------------------
# Inline code is code: no typographic replacements inside it.
#
# Asciidoctor's `replacements` substitution runs after `quotes`, so by the time
# it sees a paragraph, `` `render! : Model => Try(...)` `` is already
# `<code>render! : Model =&gt; ...</code>` and the `=>`, `->`, `...`, `--` and
# apostrophe rules rewrite Roc into arrows, ellipses and curly quotes. A reader
# who copies that code gets something the compiler rejects.
#
# Both converters emit a monospace span as `<code ...>...</code>` at that point
# (the HTML one and asciidoctor-pdf's internal markup), so this applies the
# replacements to the text between code spans only. Prose keeps its dashes and
# curly quotes. scripts/build_manual.py fails the build if a replaced character
# ever reaches a code span again.
module RocRayLiteralCodeSpans
  CODE_SPAN_RX = %r{(<code\b[^>]*>.*?</code>)}m

  def sub_replacements(text)
    return super unless text.include? "<code"

    # With a capture group, split alternates prose (even) and code (odd).
    text.split(CODE_SPAN_RX, -1).each_with_index.map do |part, index|
      index.odd? ? part : super(part)
    end.join
  end
end
Asciidoctor::Substitutors.prepend RocRayLiteralCodeSpans

Asciidoctor::Extensions.register do
  # -------------------------------------------------------------------------
  # Every rendered diagram links to its full-size SVG. A wide sequence diagram
  # has to shrink to the text column on a narrow screen; the link lets the
  # reader open it at its own size.
  tree_processor do
    process do |document|
      next unless document.backend == "html5"

      document.find_by(context: :image) { |image| image.attr("target").to_s.start_with? "diag-" }.each do |image|
        next if image.attr? "link"

        image.set_attr "link", image.image_uri(image.attr("target"))
        image.set_attr "window", "_blank"
      end
      nil
    end
  end

  # -------------------------------------------------------------------------
  # The web manual offers the PDF only when the build produced one. Build with
  # `--pdf` (as CI does) to keep the link; an HTML-only build drops it rather
  # than publishing a link to a missing file.
  postprocessor do
    process do |document, output|
      next output unless document.backend == "html5"
      next output if document.attr? "manual-pdf"

      output
        .gsub(%r{\s*(?:&#183;|·)\s*<a href="roc-ray\.pdf"[^>]*>.*?</a>\.?}m, "")
        .gsub(%r{<a href="roc-ray\.pdf"[^>]*>.*?</a>\.?}m, "")
    end
  end
end

# ---------------------------------------------------------------------------
# Tables scroll inside their own box. A table is emitted as a bare `<table>`,
# which cannot be the scroll container for its own overflow without losing its
# table layout, so the HTML converter wraps each one in a block that can.
class RocRayHtml5Converter < (Asciidoctor::Converter.for "html5")
  register_for "html5"

  def convert_table(node)
    %(<div class="table-scroll">\n#{super}\n</div>)
  end

  # The manual sets no `icons` attribute, which keeps Font Awesome (a
  # third-party request) out of the page. Without it a callout in code renders
  # as a bare "(1)". Emit the markup `icons=font` uses instead; roc-ray.css
  # draws the number in a disc from `data-value`, with no icon font. The
  # "(1)" text stays for copy, screen readers and unstyled views.
  def convert_inline_callout(node)
    %(<i class="conum" data-value="#{node.text}"></i><b>(#{node.text})</b>)
  end
end
