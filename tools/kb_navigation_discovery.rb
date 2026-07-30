# frozen_string_literal: true

require 'digest'

module KbNavigationDiscovery
  SIGNAL = /(?:
    (?<!<)(?:->|→)|\s>\s|
    vpsadmin.{0,240}(?:->|→|\bmenu\b|\bsection\b|\bdetails?\b|\bprofile\b|\bform\b|profil|detail|formulář|nabídk\w*|nabídc\w*|panel)|
    (?:\bmenu\b|\bdetails?\b|\bform\b|sidebar|nabídk\w*|nabídc\w*|detail\w*|formulář\w*|panel\w*).{0,240}(?:->|→|\/\/|\*\*)|
    (?:\/\/|\*\*)[^\n]{0,160}(?:->|→)[^\n]{0,160}(?:\/\/|\*\*)|
    \bmenu\s+[[:upper:]][^.,;:]{1,60}|
    [[:upper:]][[:alpha:] ]{1,60}\s+menu\b|
    (?:section|sekci|odkaz|link|action|funkce).{0,180}(?:vpsadmin|\*\*|["„])|
    (?:\*\*|["“„]).{0,180}(?:details?|detailu|sidebar)|
    (?:VPS.{0,100}details?|details?.{0,100}VPS)
  )/imx

  module_function

  def discover(language:, page:, content:)
    paragraphs(content).each_with_index.filter_map do |paragraph, paragraph_index|
      normalized = normalize(paragraph)
      next if normalized.empty? || !normalized.match?(SIGNAL)

      identity = [language, page, paragraph_index, normalized].join("\0")
      entry = {
        'id' => Digest::SHA256.hexdigest(identity)[0, 16],
        'language' => language,
        'page' => page,
        'paragraph' => paragraph_index,
        'text' => normalized
      }
      paths = paragraph.scan(/<vpsadmin-nav\s+id="([a-z][a-z0-9.-]*)">/).flatten
      entry['paths'] = paths unless paths.empty?
      entry
    end
  end

  def paragraphs(content)
    content.gsub(%r{<(?:code|file)\b.*?</(?:code|file)>}mi, '').split(/\n[ \t]*\n+/)
  end

  def semantic_content(content)
    content
      .gsub(%r{<(?:code|file|nowiki)\b.*?</(?:code|file|nowiki)>}mi, '')
      .gsub(/%%.*?%%/m, '')
  end

  def normalize(paragraph)
    paragraph
      .gsub(%r{</?vpsadmin-nav(?:\s+[^>]*)?>}, '')
      .lines
      .reject { |line| line.lstrip.start_with?('{{') }
      .join(' ')
      .gsub(/\s+/, ' ')
      .strip
  end
end
