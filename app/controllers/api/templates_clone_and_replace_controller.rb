# frozen_string_literal: true

module Api
  class TemplatesCloneAndReplaceController < ApiBaseController
    load_and_authorize_resource :template

    # POST /api/templates/:template_id/clone_and_replace
    #
    # Clones an existing template and swaps its attached document(s) with the
    # PDFs supplied in the request body. Field positions defined on the
    # original template are preserved (DocuSeal scales coordinates relative
    # to the new attachment), so callers can ship a freshly generated PDF
    # for every signing flow without paying for the Pro Edition templates/pdf
    # endpoint.
    #
    # Body (JSON):
    #   {
    #     "name": "optional new template name",
    #     "documents": [
    #       { "name": "contrat.pdf", "file": "data:application/pdf;base64,..." }
    #     ]
    #   }
    def create
      authorize!(:create, @template)

      return render(json: { error: 'documents required' }, status: :unprocessable_content) if params[:documents].blank?

      ActiveRecord::Associations::Preloader.new(
        records: [@template],
        associations: [{ schema_documents: :preview_images_attachments }]
      ).call

      cloned_template = Templates::Clone.call(
        @template,
        author: current_user,
        name: params[:name].presence || @template.name,
        external_id: params[:external_id].presence,
        folder_name: params[:folder_name]
      )
      cloned_template.source = :api
      cloned_template.save!

      uploaded_files = build_uploaded_files(params[:documents])
      replace_params = { 'files' => uploaded_files }

      documents = Templates::ReplaceAttachments.call(cloned_template, replace_params, extract_fields: true)

      Templates.maybe_assign_access(cloned_template)
      cloned_template.save!

      Templates::CloneAttachments.call(
        template: cloned_template,
        original_template: @template,
        excluded_attachment_uuids: documents.map(&:uuid)
      )

      WebhookUrls.enqueue_events(cloned_template, 'template.created')
      SearchEntries.enqueue_reindex(cloned_template)

      render json: Templates::SerializeForApi.call(cloned_template, schema_documents: documents)
    end

    private

    def build_uploaded_files(documents_param)
      Array(documents_param).filter_map do |doc|
        attrs = doc.respond_to?(:to_unsafe_h) ? doc.to_unsafe_h : doc.to_h
        file_value = attrs['file'] || attrs[:file]
        next unless file_value

        decoded, content_type = decode_data_uri(file_value)
        filename = attrs['name'] || attrs[:name] || 'document.pdf'

        tempfile = Tempfile.new(['docuseal-clone-replace', File.extname(filename).presence || '.pdf'])
        tempfile.binmode
        tempfile.write(decoded)
        tempfile.rewind

        ActionDispatch::Http::UploadedFile.new(
          tempfile: tempfile,
          filename: filename,
          type: content_type || 'application/pdf'
        )
      end
    end

    def decode_data_uri(value)
      if value.is_a?(String) && value.start_with?('data:')
        header, b64 = value.split(',', 2)
        content_type = header.match(/data:([^;]+)/) { |m| m[1] }
        [Base64.decode64(b64.to_s), content_type]
      else
        [Base64.decode64(value.to_s), nil]
      end
    end
  end
end
