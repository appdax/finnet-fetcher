require 'typhoeus'
require 'nokogiri'
require 'open-uri'

# The `Fetcher` class scrapes finanzen.net to get a list of all stocks.
# To do so it extracts all indexes from the search form to make a search
# request to get all stocks per index. In case of a paginated response it
# follows all subsequent linked pages.
#
# @example Fetch all stocks.
#   Fetcher.new.run
#   #=> [http://www.finanzen.net/aktien/adidas-Aktie, ...]
#
# @example Fetch all stocks from DAX and NASDAQ.
#   Fetcher.new.run(['aktien/aktien_suche.asp?inIndex=0',
#                    'aktien/aktien_suche.asp?inIndex=9'])
#   #=> [http://www.finanzen.net/aktien/adidas-Aktie, ...]
#
# @example Get a list of all stock indexes.
#   Fetcher.new.indexes
#   #=> [http://www.finanzen.net/aktien/adidas-Aktie, ...]
#
# @example Get a list of all stocks of the DAX index.
#   Fetcher.new.stocks('aktien/aktien_suche.asp?inIndex=1')
#   #=> [http://www.finanzen.net/aktien/adidas-Aktie, ...]
#
# @example Linked pages of the NASDAQ 100.
#   Fetcher.new.linked_pages('aktien/aktien_suche.asp?inIndex=9')
#   #=> ['aktien/aktien_suche.asp?intpagenr=2&inIndex=9',
#        'aktien/aktien_suche.asp?intpagenr=3&inIndex=9', ...]
class Fetcher
  # Intialize the fetcher.
  #
  # @return [ Fetcher ] A new fetcher instance.
  def initialize
    @hydra  = Typhoeus::Hydra.new
    @stocks = []
  end

  # Scrape all indexes from the page found under the `inIndex` menu.
  #
  # @example Scrape the indexes found at finanzen.net.
  #   indexes
  #   #=> [1, 2, 3, ...]
  #
  # @return [ Array<Int> ] All found stock indexes.
  def indexes
    sel  = '#frmAktienSuche table select[name="inIndex"] option:not(:first-child)' # rubocop:disable Metrics/LineLength
    body = open(abs_url('aktien/aktien_suche.asp'))
    page = Nokogiri::HTML(body, nil, 'UTF-8')

    page.css(sel).map { |opt| opt['value'] }
  rescue Timeout::Error
    []
  end

  # Scrape all stocks found on the specified search result page.
  #
  # @example Scrape stocks of the DAX index
  #   stocks('aktien/aktien_suche.asp?inIndex=1')
  #   #=> [http://www.finanzen.net/aktien/adidas-Aktie,
  #        http://www.finanzen.net/aktien/Allianz-Aktie, ...]
  #
  # @param [ Nokogiri::HTML ] page A parsed search result page.
  #
  # @return [ Array<String> ] List of URIs pointing to each stocks page.
  def stocks(page)
    sel = '#mainWrapper > div.main > div.table_quotes > div.content > table tr > td:not(.no_border):first-child > a:first-child' # rubocop:disable Metrics/LineLength

    page.css(sel).map { |link| link['href'][8..-7] }
  end

  # Determine whether the fetcher has to follow linked lists in case of
  # pagination. To follow is only required if the URL of the response
  # does not include the `intpagenr` query attribute.
  #
  # @example Follow paginating of the 1st result page of the NASDAQ.
  #   follow_linked_pages? 'aktien/aktien_suche.asp?inIndex=9'
  #   #=> true
  #
  # @example Follow paginating of the 2nd result page of the NASDAQ.
  #   follow_linked_pages? 'aktien/aktien_suche.asp?inIndex=9&intpagenr=2'
  #   #=> false
  #
  # @param [ String ] url The URL of the HTTP request.
  #
  # @return [ Boolean ] true if the linked pages have to be scraped as well.
  def follow_linked_pages?(url)
    url.to_s.length <= 80 # URL with intpagenr has length > 80
  end

  # Scrape all linked lists found on the specified search result page.
  #
  # @example Linked pages of the NASDAQ 100.
  #   linked_pages('aktien/aktien_suche.asp?inIndex=9')
  #   #=> ['aktien/aktien_suche.asp?intpagenr=2&inIndex=9',
  #        'aktien/aktien_suche.asp?intpagenr=3&inIndex=9']
  #
  # @param [ Nokogiri::HTML ] page A parsed search result page.
  #
  # @return [ Array<String> ] List of URIs pointing to each linked page.
  def linked_pages(page)
    sel = '#mainWrapper > div.main > div.table_quotes > div.content > table tr:last-child div.paging > a:not(.image_button_right)' # rubocop:disable Metrics/LineLength
    page.css(sel).map { |link| abs_url link['href'] }
  end

  # Run the hydra with the given links to scrape the stocks from the response.
  # By default all indexes form search page will be added.
  #
  # @example Fetch all stocks from DAX and NASDAQ.
  #   run(['aktien/aktien_suche.asp?inIndex=0',
  #        'aktien/aktien_suche.asp?inIndex=9'])
  #   #=> [http://www.finanzen.net/aktien/adidas-Aktie, ...]
  #
  # @example Fetch all stocks from all indexes.
  #   run()
  #   #=> [http://www.finanzen.net/aktien/adidas-Aktie, ...]
  #
  # @param [ Array<String> ] Optional list of stock indexes.
  #
  # @return [ Array<String> ] Array of links to all found stocks.
  def run(indizes = indexes)
    url = 'aktien/aktien_suche.asp?inBranche=0&inLand=0'

    indizes.each { |index| scrape abs_url("#{url}&inIndex=#{index}") }

    @hydra.run
    @stocks.dup
  ensure
    @stocks.clear
  end

  private

  # Scrape the listed stocks from the search result for a pre-given index.
  # The method workd async as the `on_complete` callback of the response
  # object delegates to the fetchers `on_complete` method.
  #
  # @param [ String ] url A absolute URL of a page with search results.
  #
  # @return [ Void ]
  def scrape(url)
    req = Typhoeus::Request.new(url)

    req.on_complete(&method(:on_complete))

    @hydra.queue req
  end

  # Callback of the `scrape` method once the request is complete.
  # The containing stocks will be saved to into a file. If the list is
  # paginated then the linked pages will be added to the queue.
  #
  # @param [ Typhoeus::Response ] res The response of the HTTP request.
  #
  # @return [ Void ]
  def on_complete(res)
    url   = res.request.url
    page  = Nokogiri::HTML(res.body, nil, 'UTF-8')
    links = stocks(page)

    linked_pages(page).each { |site| scrape site } if follow_linked_pages? url
  rescue
    $stderr.puts "[Error] #{url}"
  ensure
    @stocks.concat(links) if defined? links
  end

  # Add host and protocol to the URI to be absolute.
  #
  # @example
  #   abs_url('aktien/aktien_suche.asp')
  #   #=> 'http://www.finanzen.net/aktien/aktien_suche.asp'
  #
  # @param [ String ] A relative URI.
  #
  # @return [ String ] The absolute URI.
  def abs_url(url)
    "http://www.finanzen.net/#{url}"
  end
end
