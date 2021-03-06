class Rank::Public::Node::ThisWeeksController < Rank::Public::NodeController
  def pre_dispatch
    @node = Page.current_node
    @content = Rank::Content::Rank.find(Page.current_node.content_id)
  end

  def index
    @ranks = Rank::TotalsFinder.new(@content.ranks)
                               .search(@content, 'this_weeks', 'pageviews')
                               .paginate(page: params[:page], per_page: 20)
    return http_error(404) if @ranks.current_page > @ranks.total_pages
  end
end
