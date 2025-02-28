require 'mail'
require 'net/http'
require 'aws-sdk-s3'
require 'sanitize'

module Griddler
  module AmazonS3SES
    class Adapter
      attr_reader :sns_json

      def initialize(params)
        @sns_json = params
      end

      def self.normalize_params(params)
        adapter = new(params)
        adapter.normalize_params
      end

      def normalize_params
        sns_msg = AWS::SnsMessage.new sns_json
        raise "Invalid SNS message" unless sns_msg.authentic? && sns_msg.topic_arn.end_with?('griddler')

        case sns_msg.type
        when :SubscriptionConfirmation
          confirm_sns_subscription_request
          # this is not an actual email reply (and griddler has no way to bail at this point), so return empty parameters
          {}
        when :Notification
          ensure_valid_notification_type!
          return {} if email_json['mail']['commonHeaders'].blank? # some test SNS notifications are like this

          sns_json.merge(
            to: recipients,
            from: sender,
            cc: cc,
            bcc: bcc,
            subject: subject,
            text: text_part,
            html: html_part,
            headers: raw_headers,
            attachments: attachment_files
          )
        else
          raise "Invalid SNS message type"
        end
      end

      private
      def email_json
        @email_json ||= JSON.parse(sns_json['Message'])
      end

      def notification_type
        email_json['notificationType']
      end

      def recipients
        email_json['mail']['commonHeaders']['to'] || email_json["receipt"]["recipients"]
      end

      def sender
        email_json['mail']['commonHeaders']['from'].first
      end

      def cc
        email_json['mail']['commonHeaders']['cc'] || []
      end

      def bcc
        email_json['mail']['commonHeaders']['bcc'] || []
      end

      def subject
        email_json['mail']['commonHeaders']['subject']
      end

      def header_array
        email_json['mail']['headers']
      end

      def message
        @message ||= begin
          Mail.read_from_string(email_s3_object.get.body.string.scrub)
        end
      end

      def multipart?
        message.parts.count > 0
      end

      def text_part
        text = multipart? ? message.text_part.try(:body) : sanitized_message_body
        force_body_to_utf_8_string(text)
      end

      def sanitized_message_body
        Sanitize.clean(message.try(:body)).gsub(/\r|\n|[ ]{3,}/, '')
      end

      def html_part
        force_body_to_utf_8_string(multipart? ? message.html_part.try(:body) : message.try(:body))
      end

      def force_body_to_utf_8_string(message_body)
        # Fallback to an empty string literal to ensure we don't have nil.to_s which returns a frozen string.
        # A frozen string errors out with the .force_encoding method.
        body_string = message_body.present? ? message_body.to_s : ""

        body_string.force_encoding(Encoding::UTF_8).scrub
      end

      def raw_headers
        # SNS gives us an array of hashes with name value, which we need to convert back to raw headers;
        # based on griddler-sparkpost (https://github.com/PrestoDoctor/griddler-sparkpost, MIT license)
        header_array.inject([]) { |raw_headers, sns_hash|
          raw_headers.push("#{sns_hash['name']}: #{sns_hash['value']}")
        }.join("\r\n")
      end

      def attachment_files
        # also based on griddler-sparkpost (https://github.com/PrestoDoctor/griddler-sparkpost, MIT license);
        # AWS doesn't presently support sending the attachments from the message through SNS, but ready if they do!
        message.attachments.map do |attachment|
          ActionDispatch::Http::UploadedFile.new({
            type: attachment.mime_type,
            filename: filename_for(attachment),
            tempfile: tempfile_for_attachment(attachment)
          })
        end
      end

      def tempfile_for_attachment(attachment)
        filename = filename_for(attachment).gsub(/\/|\\/, '_')
        tempfile = Tempfile.new(filename, Dir::tmpdir, encoding: 'ascii-8bit')
        content = attachment.body.decoded
        tempfile.write(content)
        tempfile.rewind
        tempfile
      end

      def filename_for(attachment)
        attachment.inline? ? attachment.cid : attachment.filename
      end

      def ensure_valid_notification_type!
        raise "Invalid SNS notification type (\"#{notification_type}\", expecting Received" unless notification_type == 'Received'
      end

      def confirm_sns_subscription_request
        confirmation_endpoint = URI.parse(sns_json['SubscribeURL'])
        Net::HTTP.get confirmation_endpoint
      rescue StandardError
        Rails.logger.error "Error confirming subscription #{confirmation_endpoint} #{$!.inspect}"
      end

      def s3
        @s3 ||= Aws::S3::Resource.new(region: Griddler::AmazonS3SES.configuration.aws_region)
      end

      def email_s3_object
        @email_s3_object ||=
          s3
          .bucket(email_json['receipt']['action']['bucketName'])
          .object(email_json['receipt']['action']['objectKey'])
      end
    end
  end
end
