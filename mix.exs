defmodule CloudIServiceQuorum do
  use Mix.Project

  def project do
    [app: :cloudi_service_quorum,
     version: "1.4.0-rc.4",
     language: :erlang,
     description: description,
     package: package,
     deps: deps]
  end

  defp deps do
    [{:proper,
      [git: "https://github.com/manopapad/proper.git",
       tag: "v1.1"]},
     {:cloudi_core, "~> 1.4.0-rc.4"}]
  end

  defp description do
    "Erlang/Elixir Cloud Framework Quorum Service"
  end

  defp package do
    [files: ~w(src doc test rebar.config README.markdown),
     contributors: ["Michael Truog"],
     licenses: ["BSD"],
     links: %{"Website" => "http://cloudi.org",
              "GitHub" => "https://github.com/CloudI/" <>
                          "cloudi_service_quorum"}]
   end
end
