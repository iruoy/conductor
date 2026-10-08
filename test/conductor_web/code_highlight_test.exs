defmodule ConductorWeb.CodeHighlightTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ConductorWeb.RunComponents

  test "write content is highlighted by file extension across native and syntect lexers" do
    for {path, source} <- [
          {"file.ex", "defmodule Example do\n  def value, do: 42\nend"},
          {"file.erl", "-module(example).\nvalue() -> 42."},
          {"file.html", "<div>hello</div>"},
          {"file.heex", "<div>{@value}</div>"},
          {"file.eex", "<%= value %>"},
          {"file.json", "{\"value\": 42}"},
          {"file.ts", "export const value: number = 42;"}
        ] do
      html =
        render_component(&RunComponents.tool/1,
          id: "code-tool",
          name: "write",
          args: %{"path" => path, "content" => source}
        )

      document = LazyHTML.from_fragment(html)
      code = LazyHTML.query(document, "#code-tool pre.tool-code")
      assert LazyHTML.text(code) == source
      assert LazyHTML.query(code, "span") |> Enum.any?(), path
    end
  end

  test "Makeup diff preserves numbered lines, whitespace and addition/deletion tokens" do
    source = "  1 same\n- 2 old\n+ 2 new\n+ 3 more\n  3 rest"
    html = ConductorWeb.CodeHighlight.diff(source) |> Phoenix.HTML.safe_to_string()
    document = LazyHTML.from_fragment(html)
    assert LazyHTML.text(document) == source
    assert LazyHTML.text(LazyHTML.query(document, ".gd")) == "- 2 old"
    assert LazyHTML.text(LazyHTML.query(document, ".gi")) == "+ 2 new+ 3 more"
  end

  test "highlighted HTML is escaped, not executable" do
    source = "<script>alert('x')</script>"
    html = ConductorWeb.CodeHighlight.render(source, "file.html") |> Phoenix.HTML.safe_to_string()
    document = LazyHTML.from_fragment(html)
    assert LazyHTML.text(document) == source
    assert LazyHTML.query(document, "script") |> Enum.empty?()
  end

  test "unknown extensions and absent paths remain literal" do
    for path <- ["file.unknown-extension", nil] do
      source = "<svg onload='alert(1)'> & hello"
      html = ConductorWeb.CodeHighlight.render(source, path) |> Phoenix.HTML.safe_to_string()
      document = LazyHTML.from_fragment(html)
      assert LazyHTML.text(document) == source
      assert LazyHTML.query(document, "*") |> Enum.empty?()
    end
  end

  test "bash keeps its ANSI output and does not get code highlighting" do
    html =
      render_component(&RunComponents.tool/1,
        id: "bash-tool",
        name: "bash",
        args: %{"command" => "echo hello"},
        output: "\e[32mhello\e[0m"
      )

    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "#bash-tool .tool-code") |> Enum.empty?()
    assert LazyHTML.text(LazyHTML.query(document, "#bash-tool-output")) == "hello"
  end
end
