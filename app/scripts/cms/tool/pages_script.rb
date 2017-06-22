class Cms::Tool::PagesScript < Cms::Script::Base
  include Cms::Controller::Layout

  def rebuild
    nodes = Cms::Node.where(id: params[:node_id])

    ::Script.total nodes.size

    nodes.each do |node|
      ::Script.progress(node) do
        page = Cms::Node::Page.find(node.id)
        page.rebuild
      end
    end
  end
end
