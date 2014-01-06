require 'SVG/Graph/Line'
require 'json'

[:time, :size].each do |type|

  @commits = []
  @data = {}

  File.read("tmp/bench_#{type}.log").each_line do |line|
    commit, dat = *line.split(" ", 2)
    @commits << commit
    [:utxo, :sequel].each {|backend| [:sqlite, :postgres, :mysql].each {|adapter|
        name = "#{backend}_#{adapter}"
        @data[name] ||= []
        @data[name] << JSON.parse(dat)[name]
      }}
  end

  graph = SVG::Graph::Line.new(height: 500, width: 1000, fields: @commits)
  graph.rotate_x_labels = true
  graph.scale_integers = true
  [
#    :utxo,
    :sequel
  ].each {|backend|
    [
#      :sqlite,
      :postgres,
#      :mysql
    ].each {|adapter|
      name = "#{backend}_#{adapter}"
      p @data[name]
      graph.add_data(data: @data[name], title: name)
    }}

File.open("graph_#{type}.svg", "w") {|f|
 # f.write "Content-type: image/svg+xml\r\n\r\n"
  f.write graph.burn()
}
end
