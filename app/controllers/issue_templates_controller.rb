# noinspection ALL
class IssueTemplatesController < ApplicationController
  layout 'base'
  helper :issues
  include Concerns::IssueTemplatesCommon
  include Concerns::ProjectTemplatesCommon
  menu_item :issues
  before_action :find_tracker, :find_templates, only: %i[set_pulldown list_templates]

  def index
    project_id = @project.id
    project_templates = IssueTemplate.search_by_project(project_id)

    # pick up used tracker ids
    tracker_ids = @project.trackers.pluck(:id)

    @template_map = {}
    tracker_ids.each do |tracker_id|
      templates = project_templates.search_by_tracker(tracker_id).sorted
      @template_map[Tracker.find(tracker_id)] = templates if templates.any?
    end

    setting = IssueTemplateSetting.find_or_create(project_id)
    @inherit_templates = setting.get_inherit_templates

    @global_issue_templates = global_templates(tracker_ids)

    respond_to do |format|
      format.html do
        render layout: !request.xhr?,
               locals: { apply_all_projects: apply_all_projects?, tracker_ids: tracker_ids }
      end
      format.api do
        render formats: :json, locals: { project_templates: project_templates }
      end
    end
  end

  def new
    if params[:copy_from].present?
      @issue_template = IssueTemplate.find(params[:copy_from]).dup
      @issue_template.title = @issue_template.copy_title
    else
      # create empty instance
      @issue_template ||= IssueTemplate.new(author: @user, project: @project)
    end
    render render_form_params
  end

  def create
    @issue_template = IssueTemplate.new(valid_params)
    @issue_template.author = User.current
    @issue_template.project = @project
    # TODO: Should return validation error in case mandatory fields are blank.
    save_and_flash(:notice_successful_create, :new) && return
  end

  def update
    @issue_template.safe_attributes = valid_params
    save_and_flash(:notice_successful_update, :show)
  end

  # load template description
  def load
    issue_template_id = params[:template_id]
    template_type = params[:template_type]
    issue_template = if !template_type.blank? && template_type == 'global'
                       GlobalIssueTemplate.find(issue_template_id)
                     else
                       IssueTemplate.find(issue_template_id)
                     end
    render plain: issue_template.template_json
  end

  # update pulldown
  def set_pulldown
    @group = []
    @default_template = nil

    add_templates_to_group(@issue_templates)
    add_templates_to_group(@inherit_templates, class: 'inherited')
    add_templates_to_group(@global_templates, class: 'global')

    is_triggered_by = request.parameters[:is_triggered_by]
    is_update_issue = request.parameters[:is_update_issue]
    @group[@default_template].selected = 'selected' if @default_template.present? && (is_update_issue.blank? || is_update_issue != 'true')

    render action: '_template_pulldown', layout: false,
           locals: { is_triggered_by: is_triggered_by, grouped_options: @group,
                     should_replaced: setting.should_replaced, default_template: @default_template }
  end

  #
  # List templates associated with tracker and project.
  # TODO: refactor here. Duplicate with set_pulldown....
  #
  def list_templates
    (default_global, default_inherit, default_project) = default_templates

    default_template = default_inherit.present? ? default_inherit : default_global
    default_template = default_project.present? ? default_project : default_template

    respond_to do |format|
      format.html do
        render action: '_list_templates',
               layout: false,
               locals: { default_template: default_template,
                         issue_templates: @issue_templates,
                         inherit_templates: @inherit_templates,
                         global_issue_templates: @global_templates }
      end
      format.api do
        render action: '_list_templates',
               locals: { default_template: default_template,
                         issue_templates: @issue_templates,
                         inherit_templates: @inherit_templates,
                         global_issue_templates: @global_templates }
      end
    end
  end

  # preview
  def preview
    issue_template = params[:issue_template]
    @text = (issue_template ? issue_template[:description] : nil)
    render partial: 'common/preview'
  end

  private

  def orphaned
    IssueTemplate.orphaned(@project.id)
  end

  def find_object
    @issue_template = IssueTemplate.find(params[:id])
    @project = @issue_template.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_templates
    @issue_templates = issue_templates
    @inherit_templates = inherit_templates
    @global_templates = global_templates(@tracker.id)
  end

  def template
    @issue_template
  end

  def setting
    IssueTemplateSetting.find_or_create(@project.id)
  end

  def global_templates(tracker_id)
    return [] if apply_all_projects? && templates_exist?

    project_id = apply_all_projects? ? nil : @project.id
    GlobalIssueTemplate.get_templates_for_project_tracker(project_id, tracker_id)
  end

  def default_templates
    [@global_templates, @inherit_templates, @issue_templates].map do |templates|
      templates.try(:is_default).try(:first)
    end
  end

  def default_template_index
    @default_template.blank? ? @group.length - 1 : @default_template
  end

  def add_templates_to_group(templates, option = {})
    templates.each do |template|
      @group << template.template_struct(option)
      next unless template.is_default == true

      @default_template = default_template_index
    end
  end

  def issue_templates
    IssueTemplate.get_templates_for_project_tracker(@project.id, @tracker.id)
  end

  def inherit_templates
    setting.get_inherit_templates(@tracker)
  end

  def template_params
    params.require(:issue_template).permit(:tracker_id, :title, :note, :issue_title, :description, :is_default,
                                           :enabled, :author_id, :position, :enabled_sharing, checklists: [])
  end

  def templates_exist?
    @inherit_templates.present? || @issue_templates.present?
  end

  def render_form_params
    { layout: !request.xhr?,
      locals: { issue_template: template, project: @project,
                checklist_enabled: checklist_enabled? } }
  end
end
