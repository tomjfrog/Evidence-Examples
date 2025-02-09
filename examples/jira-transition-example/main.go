package main
import (
    "context"
    "encoding/json"
    "os"
    "fmt"
    jira "github.com/andygrunwald/go-jira/v2/cloud"
  )
  /*
    JiraTransitionResponse is the json formatted predicate that will be returned to the calling build process for cresting an evidence
    its structure should be:

    {
    "transition": "<transition-name>",
    "allJiraTransitionsFound": "<true/false>",
    "tasks": [
        {
        "jira_id": "<jira-id>",
        "summary": "<summary>",
        "transition_found": "<true/false>"
        "author": "<user display name>",
        "author_user_name": "<user email>",
        "transition_time": "2025-02-04T08:14:03.559+0200"
        }
    ]
   }

   notice that the calling client should first check that return value was 0 before using the response JSON,
   otherwise the response is an error message which cannot be parsed
   */

type TransitionCheckResponse struct {
    Transition string `json:"transition"`
    AllJiraTransitionsFound bool `json:"allJiraTransitionsFound"`
    Tasks []JiraTransitionResult `json:"tasks"`
}

type JiraTransitionResult struct {
	JiraId           string `json:"jira_id"`
	Summary          string `json:"summary"`
	TransitionFound  bool   `json:"transition_found"`
	Author           string `json:"author"`
	AuthorEmail   string `json:"author_user_name"`
	TransitionTime          string `json:"transition_time"`
}

func main() {
    // get checked transition name and JIRA IDs from command-line arguments
	if len(os.Args) < 3 {
        fmt.Println("No command-line arguments provided, please send checked transition name and at least one JIRA ID(s)")
        return
    }
    transitionChecked := os.Args[1]
    // Create a new Jira client
    jira_token := os.Getenv("jira_token")
    if jira_token == "" {
        fmt.Println("JIRA token not found, set jira_token variable")
        os.Exit(1)
    }
    jira_url := os.Getenv("jira_url")
    if jira_url == "" {
        fmt.Println("JIRA URL not found, set jira_url variable")
        os.Exit(1)
    }
    jira_username := os.Getenv("jira_username")
    if jira_username == "" {
        fmt.Println("JIRA username not found, set jira_username variable")
        os.Exit(1)
    }
    // connect to JIRA
    tp := jira.BasicAuthTransport{
        Username: jira_username,
		APIToken: jira_token,
	}
    client, err := jira.NewClient(jira_url, tp.Client())
    if err != nil {
		fmt.Println("jira.NewClient error: %v\n", err)
		os.Exit(1)
	}
    // initialize the response
    transitionCheckResponse := TransitionCheckResponse{}
    transitionCheckResponse.AllJiraTransitionsFound = true
    transitionCheckResponse.Transition = transitionChecked
    transitionFound := false
    // loop over all JIRAs sent to the fucntion
    for _, jiraId := range os.Args[2:] {
        //fmt.Println("-----------Checking JIRA ", jiraId)
        transitionFound = false
        issue, _, _ := client.Issue.Get(context.Background(), jiraId , &jira.GetQueryOptions{Expand: "changelog"})
        if issue == nil {
            fmt.Println("Got error for extracting issue with jira id: ", jiraId, "error", err)
            os.Exit(1)
        }
         // adding the jira result to the list of results
        jiraTransitionResult := JiraTransitionResult{
            JiraId: jiraId,
            Summary: issue.Fields.Summary,
        }

        if len(issue.Changelog.Histories) > 0 {
            //fmt.Println("history found for jira id:", jiraId)
            for _, history := range issue.Changelog.Histories {
                for _, changelogItems := range history.Items {
                    //fmt.Println("jira id:", jiraId, "field", changelogItems.Field, "FieldType",  changelogItems.FieldType, "toString",  changelogItems.ToString)
                    if changelogItems.Field == "status" {
                        //fmt.Println("Transition for jira", jiraId, "FromString", changelogItems.FromString, "ToString" , changelogItems.ToString, "Created", history.Created, "Author", history.Author)
                        if changelogItems.ToString == transitionChecked {
                            transitionFound = true
                            jiraTransitionResult.Author = history.Author.DisplayName
                            jiraTransitionResult.AuthorEmail = history.Author.EmailAddress
                            jiraTransitionResult.TransitionTime = history.Created
                           // fmt.Println("Transition name for jira", jiraId, "found")
                            break // once found we can continue to the next jira
                        }
                    }
                }
            }
        }
        jiraTransitionResult.TransitionFound = transitionFound
        transitionCheckResponse.Tasks = append(transitionCheckResponse.Tasks, jiraTransitionResult)
        // check if all transitions are found
        if !transitionFound {
            transitionCheckResponse.AllJiraTransitionsFound = false
        }
    }
    // marshal the response to JSON
	jsonBytes, err := json.Marshal(transitionCheckResponse)
	if err != nil {
		fmt.Println("Error marshaling JSON", err)
		os.Exit(1)
	}
	//logger.Println("returning response", response)

	// return response to caller through stdout
	os.Stdout.Write(jsonBytes)
 }
