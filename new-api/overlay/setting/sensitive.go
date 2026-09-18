package setting

import (
	"strconv"

	"strings"
)

var CheckSensitiveEnabled = true
var CheckSensitiveOnPromptEnabled = true

//var CheckSensitiveOnCompletionEnabled = true

// StopOnSensitiveEnabled 如果检测到敏感词，是否立刻停止生成，否则替换敏感词
var StopOnSensitiveEnabled = true

// SensitiveWordExemptUserIDs 豁免敏感词检查的用户ID列表
var SensitiveWordExemptUserIDs []int

// StreamCacheQueueLength 流模式缓存队列长度，0表示无缓存
var StreamCacheQueueLength = 0

// SensitiveWords 敏感词
// var SensitiveWords []string
var SensitiveWords = []string{
	"test_sensitive",
}

func SensitiveWordsToString() string {
	return strings.Join(SensitiveWords, "\n")
}

func SensitiveWordsFromString(s string) {
	SensitiveWords = []string{}
	sw := strings.Split(s, "\n")
	for _, w := range sw {
		w = strings.TrimSpace(w)
		if w != "" {
			SensitiveWords = append(SensitiveWords, w)
		}
	}
}


func SensitiveWordExemptUserIDsToString() string {
	parts := make([]string, 0, len(SensitiveWordExemptUserIDs))
	for _, id := range SensitiveWordExemptUserIDs {
		parts = append(parts, strconv.Itoa(id))
	}
	return strings.Join(parts, ",")
}

func SensitiveWordExemptUserIDsFromString(s string) {
	SensitiveWordExemptUserIDs = []int{}
	parts := strings.Split(s, ",")
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		id, err := strconv.Atoi(p)
		if err == nil {
			SensitiveWordExemptUserIDs = append(SensitiveWordExemptUserIDs, id)
		}
	}
}

func IsSensitiveWordExempt(userID int) bool {
	for _, id := range SensitiveWordExemptUserIDs {
		if id == userID {
			return true
		}
	}
	return false
}

func ShouldCheckPromptSensitive() bool {
	return CheckSensitiveEnabled && CheckSensitiveOnPromptEnabled
}

//func ShouldCheckCompletionSensitive() bool {
//	return CheckSensitiveEnabled && CheckSensitiveOnCompletionEnabled
//}
